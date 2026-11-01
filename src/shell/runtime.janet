# Shell runtime (ADR 0009): the imperative half of ADR 0001. It owns the state,
# a re-entrancy-free event queue, and executes effects through a `ctx` port.
# It imports neither Jwno nor jw32; everything that touches the OS is a
# function in `ctx`:
#   effects:   :place (id rect) :focus (id) :close (id) :goto (tag) :send (id tag) :hide (id) :show (id)
#   observe:   :foreground () -> id|nil   (root window, NOT owner-normalised)
#              :foreground-is? (id) -> bool   (exact match)
#              :current-desktop () -> tag|nil
#              :enumerate () -> [[id tag-or-nil facts] ...]   :work-area () -> rect
#   misc:      :later (seconds thunk)  :log (level msg)  :notify (kind id)
#   config:    :reassert? (default true) -- ADR 0009 R-10 switch (false = mitigation A only)
# Any port function may throw; the runtime protects every call.
# The port shape is exercised by the Jwno adapter's contract tests (hosted Windows Server and one real
# Windows 11 PC; docs/spike/2026-11-01-real-machine.md lists what is not covered).

(import ../core/update :as u)
(import ../core/state :as st)

(def- max-recoveries 3)
(def- reobserve-delay 0.2)
(def- reassert-delay 0.25)  # ADR 0009 R-10; Jwno refocuses 15-30ms after a switch on a quiet runner
(def- recovery-delay 1.0)   # longer than the re-observation: do not race the user

(defn make
  "A runtime around `ctx` with initial core state `state`."
  [ctx state]
  @{:ctx ctx :state state :queue @[] :busy false
    :failures 0           # recoveries scheduled since the last clean batch
    :recovery-pending false
    :reobserve-pending false})

(defn state [rt] (rt :state))

(defn- call
  "Call port function `name`; -> [ok? value]. Never throws (the log port too)."
  [rt name & args]
  (def f (get (rt :ctx) name))
  (if (nil? f)
    [false (string "missing port function " name)]
    (let [[ok v] (protect (f ;args))]
      (when (not ok)
        (unless (= name :log)
          (protect ((get (rt :ctx) :log identity) :error (string name ": " v)))))
      [ok v])))

(defn- log [rt level msg] (protect (((rt :ctx) :log) level msg)) nil)

# forward reference: timers call back into dispatch
(var- dispatch-fwd nil)
(defn- redispatch [rt ev] (dispatch-fwd rt ev))

(defn- pop-front [rt]
  (def ev (first (rt :queue)))
  (array/remove (rt :queue) 0)
  ev)

(defn- push-front [rt ev] (array/insert (rt :queue) 0 ev))

(defn- observe-front
  "Read the real foreground and queue it as an observation. nil is passed on
  only when `nil-ok?` (before a command: safe side, makes things non-actionable);
  otherwise nil means 'no observation' and must not erase a good :os-focus."
  [rt nil-ok?]
  (def [ok id] (call rt :foreground))
  (when (and ok (or nil-ok? id))
    (push-front rt [:focus-changed id])))

(defn- schedule-reobserve [rt]
  (unless (rt :reobserve-pending)
    (put rt :reobserve-pending true)
    (def [ok _]
      (call rt :later reobserve-delay
            (fn []
              (put rt :reobserve-pending false)
              # evaluated now, not when scheduled (ADR 0009 M1)
              (def [ok id] (call rt :foreground))
              (when (and ok id) (redispatch rt [:focus-changed id])))))
    (unless ok (put rt :reobserve-pending false))))

(defn- schedule-recovery [rt]
  (when (and (not (rt :recovery-pending)) (< (rt :failures) max-recoveries))
    (put rt :failures (+ 1 (rt :failures)))
    (put rt :recovery-pending true)
    (def [ok _]
      (call rt :later recovery-delay
            (fn []
              (put rt :recovery-pending false)
              # :goto may have failed, leaving :current ahead of the OS; only an
              # observed :desktop-changed can bring it back (idempotent if equal)
              (def [okd tag] (call rt :current-desktop))
              (when (and okd tag) (redispatch rt [:desktop-changed tag]))
              (def [ok snap] (call rt :enumerate))
              (when ok (redispatch rt [:windows-observed snap]))
              (redispatch rt [:command :refresh]))))
    (unless ok (put rt :recovery-pending false))))

(defn- execute
  "Run one effect. -> true on success (a deliberately dropped :close is success)."
  [rt fx]
  (case (first fx)
    :place (first (call rt :place (fx 1) (fx 2)))
    :focus (first (call rt :focus (fx 1)))
    :goto (first (call rt :goto (fx 1)))
    :hide (first (call rt :hide (fx 1)))        # ADR 0006: leave the visible workspace
    :show (first (call rt :show (fx 1)))        # ... and come back
    :send (first (call rt :send (fx 1) (fx 2)))
    :close
    (let [[ok same] (call rt :foreground-is? (fx 1))]
      (if (and ok same)
        (first (call rt :close (fx 1)))
        (do (call rt :notify :ignored-close (fx 1))
            (log rt :warn (string "ignored close of " (fx 1) ": not the foreground window"))
            true)))   # a deliberate drop is not a failure
    (do (log rt :warn (string "unknown effect " (first fx))) true)))

(defn- run-effects
  "-> [failed observe? n goto+focus-ok?]"
  [rt effects]
  (var failed 0)
  (var goto-failed false)
  (var goto-ok false)
  (var focus-ok false)
  (var observed-needed false)
  (each fx effects
    (cond
      (and goto-failed (= (first fx) :focus))
      (do (++ failed) (log rt :warn "skipped :focus after a failed :goto"))
      (let [ok (execute rt fx)]
        (unless ok
          (++ failed)
          (when (= (first fx) :goto) (set goto-failed true)))
        (when (and ok (= (first fx) :goto)) (set goto-ok true))
        (when (and ok (= (first fx) :focus)) (set focus-ok true))
        (when (index-of (first fx) [:focus :goto]) (set observed-needed true)))))
  [failed observed-needed (length effects) (and goto-ok focus-ok)])

(defn- schedule-reassert
  "ADR 0009 R-10: ask the core once, later, whether the :goto's focus stuck. The
  core decides (pending-focus); a late timer with nothing pending is a no-op."
  [rt]
  (when (not= false (get (rt :ctx) :reassert?))
    (call rt :later reassert-delay (fn [] (redispatch rt [:command :reassert-focus])))))

(defn- process-one
  "Process the event; -> nil. Never throws."
  [rt event]
  (def pre-observe? (= (get event 0) :command))
  (when pre-observe?
    # inline, before the command itself (ADR 0005 §3-7-1, ADR 0009 R-5)
    # a port failure is treated as "nothing is focused": the safe side
    (def [ok id] (call rt :foreground))
    (def r0 (protect (u/update (rt :state) [:focus-changed (if ok id)])))
    (when (first r0)
      (put rt :state ((last r0) :state))))
  (def [ok r] (protect (u/update (rt :state) event)))
  (if (not ok)
    (log rt :error (string "update threw: " r))
    (do
      (put rt :state (r :state))                       # R-2: save first
      (def [failed observe? n goto+focus?] (run-effects rt (r :effects)))
      (when goto+focus? (schedule-reassert rt))
      (when (> failed 0) (schedule-recovery rt))
      (when (and (zero? failed) (> n 0)) (put rt :failures 0))
      (when (or observe? (= (get event 0) :desktop-changed))
        (observe-front rt false)
        (schedule-reobserve rt)))))

(defn dispatch [rt event]
  (array/push (rt :queue) event)
  (unless (rt :busy)
    (put rt :busy true)
    (defer (put rt :busy false)
      (while (not (empty? (rt :queue)))
        (process-one rt (pop-front rt))))))

(set dispatch-fwd dispatch)

(defn start
  "Initial sync (R-7). The adapter registers its hooks BEFORE calling this;
  events that arrive meanwhile are queued and drained afterwards."
  [rt]
  (unless (rt :busy)
    (put rt :busy true)
    (defer (put rt :busy false)
      (def [ok1 area] (call rt :work-area))
      (when ok1 (process-one rt [:screen-changed area]))
      # align the core's :current with the OS before any window is placed or focused;
      # otherwise the first :focus could make the OS switch desktops (ADR 0010 N1)
      (def [okd tag] (call rt :current-desktop))
      (when (and okd tag) (process-one rt [:desktop-changed tag]))
      (def [ok2 snap] (call rt :enumerate))
      (when ok2 (process-one rt [:windows-observed snap]))
      (observe-front rt false)
      (while (not (empty? (rt :queue)))
        (process-one rt (pop-front rt))))))
