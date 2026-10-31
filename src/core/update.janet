# (update state event) -> {:state s' :effects [effect ...]}
#
# Events (input data):
#   [:window-opened id &opt tag]      [:window-closed id]
#   [:window-seen id facts &opt tag]  (ADR 0008: classify once; later only hiding)
#   [:focus-changed id-or-nil]        [:desktop-changed tag]
#   [:screen-changed rect]            [:window-moved id observed-rect]
#   [:windows-observed [[id tag-or-nil] ...]]   (snapshot, first = topmost)
#   [:command name & args]            (incl. :refresh)
#
# Effects (output data, executed by the shell):
#   [:place id rect]  [:focus id]  [:close id]
#   [:goto tag]       [:send id tag]
#
# :place / :focus effects are derived by diffing old and new state, so the
# transitions below never mention them.
#
# Observation principle: facts about the OS come only from observation events,
# and the model never assumes one of its own effects succeeded.
#  * :os-focus = the last OS focus we observed (any valid id, even unknown or on
#    another workspace); absent = unknown. Destructive commands (close, send,
#    reorder) run ONLY when the model's focus equals :os-focus ("actionable"),
#    so they can only ever hit the window the user is looking at -- even if a
#    :focus effect of ours failed (foreground lock).
#  * :focus-changed / :desktop-changed update the model but never echo a
#    :focus effect back (silent).
#  * :external-focus (OS focus is on something we do not manage) is set and
#    cleared ONLY by observations (an observed focus, or a window-opened for
#    the very id last observed as OS focus). While set, no :focus is derived
#    (we never steal focus from a dialog).
#  * :current changes only on :desktop-changed or the :goto command.
#
# Recovery from drift: [:command :refresh] re-emits every :place (and :focus
# when not external); [:window-moved id rect] re-places one window unless the
# observed rect already matches the model (so our own :place echoes die out),
# and gives up after `misfit-limit` consecutive mismatches (app enforces its
# own size); [:windows-observed ...] repairs the model itself (ghost ids,
# wrong workspace).
#
# Core never throws: malformed or ill-typed events are ignored.

(import ./data :as d)
(import ./state :as st)
(import ./workspace :as ws)
(import ./layout)
(import ./classify :as cl)

(def- ratio-step 0.03)
(def- misfit-limit 3)

# ---- validation --------------------------------------------------------

(defn- valid-id? [x] (or (number? x) (keyword? x) (string? x)))

(defn- int? [x]
  (and (number? x) (= x (math/floor x)) (< (math/abs x) 1e9)))

(defn- valid-rect? [r]
  (and (struct? r)
       (int? (get r :x)) (int? (get r :y)) (int? (get r :w)) (int? (get r :h))
       (pos? (r :w)) (pos? (r :h))))

(defn- valid-tag? [s tag] (and (string? tag) (not (nil? (index-of tag (s :tags))))))

(defn- known? [s id] (not (nil? (st/locate s id))))
(defn- external? [s] (s :external-focus))

(defn- actionable?
  "True only if the model's focused window is the one the OS last reported."
  [s]
  (def f (st/focused s))
  (and f (= f (s :os-focus))))

# ---- observations ------------------------------------------------------

(defn- open-window [s id tag]
  (cond
    (not (valid-id? id)) s
    (known? s id) s
    (and tag (not (valid-tag? s tag))) s
    (let [tag (or tag (s :current))
          s2 (st/update-ws s tag |(ws/insert $ id))]
      # Jwno reports focus on a new hwnd BEFORE :window-opened, and does not
      # repeat it. If this is the window the OS already focused, adopt that
      # observation instead of waiting for one that will never come.
      (if (and (= tag (s :current)) (= id (s :os-focus)))
        (d/assoc s2 {:external-focus false})
        s2))))

(defn- close-window [s id]
  (def tag (st/locate s id))
  (def s1 (if tag (st/update-ws s tag |(ws/remove $ id)) s))
  # forget everything keyed on this id: HWNDs get reused
  (def s1b (if (get-in s1 [:floating id])
             (d/assoc s1 {:floating (d/without (s1 :floating) id)})
             s1))
  (def s2 (if (get-in s1b [:misfit id])
            (d/assoc s1b {:misfit (d/without (s1b :misfit) id)})
            s1b))
  (if (= id (s2 :os-focus)) (d/without s2 :os-focus) s2))

(defn- set-floating [s id on?]
  (d/assoc s {:floating (if on?
                          (d/assoc (s :floating) {id true})
                          (d/without (s :floating) id))
              :misfit (d/without (get s :misfit {}) id)}))

(defn- drop-hidden
  "A known window became hidden (minimized, fullscreen, ...). If it holds the OS
  focus, keep that observation and mark focus external: the OS focus is now on
  something we do not manage, so we must not pull it to a neighbour (ADR 0008)."
  [s id]
  (def s2 (close-window s id))
  (if (= id (s :os-focus))
    (d/assoc s2 {:os-focus id :external-focus true})
    s2))

(defn- window-seen
  "Classify once, when a window becomes known; afterwards only hiding it matters."
  [s id facts tag]
  (cond
    (or (not (valid-id? id)) (not (dictionary? facts))) s
    (known? s id) (if (cl/hidden? facts) (drop-hidden s id) s)
    (case (cl/classify (s :rules) facts)
      :tile (open-window s id tag)
      :float (let [s2 (open-window s id tag)]
               (if (known? s2 id) (set-floating s2 id true) s2))
      s)))

(defn- focus-window
  "OS focus moved. Record it; it clears `external` only when it lands on a
  window of the visible workspace. A window of another workspace is the
  pending half of a desktop switch: remember it in :os-focus (a following
  :desktop-changed adopts it), and treat focus as external meanwhile."
  [s id]
  (def tag (if (valid-id? id) (st/locate s id)))
  (cond
    (not (valid-id? id)) (-> s (d/assoc {:external-focus true}) (d/without :os-focus))
    # a window we do not know (yet): remember it, so a following :window-opened
    # for the same id is recognised as the focused one
    (nil? tag) (d/assoc s {:external-focus true :os-focus id})
    (not= tag (s :current))
    (d/assoc s {:external-focus true :os-focus id})
    (-> s
        (st/update-ws tag |(ws/focus-id $ id))
        (d/assoc {:external-focus false :os-focus id}))))

(defn- desktop-changed [s tag]
  (cond
    (not (valid-tag? s tag)) s
    (= tag (s :current)) s
    (let [id (s :os-focus)
          s2 (-> s (d/assoc {:current tag}) (d/without :os-focus))]
      (if (and id (= tag (st/locate s2 id)))
        (-> s2
            (st/update-ws tag |(ws/focus-id $ id))
            (d/assoc {:external-focus false :os-focus id}))
        (d/assoc s2 {:external-focus true})))))

(defn- windows-observed
  "Snapshot of what the OS actually has: [[id tag-or-nil] ...], first = topmost
  = master. Drops ghost ids, adds missing windows, fixes wrong workspaces. It
  is a pure observation of the window set: it returns no :focus and moves focus
  only to adopt an already-observed OS focus. A nil tag means
  'desktop unknown': a known window stays where it is, an unknown one goes to
  the visible workspace."
  [s obs]
  (if-not (indexed? obs)
    s
    (let [pairs (filter |(and (indexed? $) (valid-id? (get $ 0))
                              (or (nil? (get $ 1)) (valid-tag? s (get $ 1))))
                        obs)
          # the first occurrence of an id wins (including its facts)
          first-seen (table)
          pairs (filter |(if (first-seen (first $)) false (put first-seen (first $) true))
                        pairs)
          # an optional 3rd element is facts; invalid facts count as absent
          facts-of (fn [e] (let [f (get e 2)] (if (dictionary? f) f)))
          hidden-ids (filter |(let [f (facts-of $)] (and f (cl/hidden? f))) pairs)
          s0 (reduce (fn [a e] (if (known? a (first e)) (drop-hidden a (first e)) a))
                     s hidden-ids)
          pairs (filter |(let [f (facts-of $)] (not (and f (cl/hidden? f)))) pairs)
          # unknown windows the rules say to ignore stay out of the set
          pairs (filter |(let [f (facts-of $)]
                           (or (nil? f) (known? s0 (first $))
                               (not= :ignore (cl/classify (s0 :rules) f))))
                        pairs)
          seen (table)
          ordered (filter |(if (seen (first $)) false (put seen (first $) true))
                          pairs)
          s1 (reduce (fn [acc tag]
                       (reduce (fn [a id] (if (seen id) a (close-window a id)))
                               acc ((st/ws-of acc tag) :ids)))
                     s0 (s0 :tags))]
      (let [acc (reduce
                  (fn [acc [id tag facts]]
                    (def have (st/locate acc id))
                    (cond
                      (nil? have)
                      (let [a2 (st/update-ws acc (or tag (acc :current)) |(ws/append $ id))
                            f (if (dictionary? facts) facts)]
                        (if (and f (= :float (cl/classify (a2 :rules) f)))
                          (set-floating a2 id true)
                          a2))
                      (or (nil? tag) (= have tag)) acc
                      (-> acc
                          (st/update-ws have |(ws/remove $ id))
                          (st/update-ws tag |(ws/append $ id)))))
                  s1 ordered)
            os (acc :os-focus)]
        # The OS focus may have been observed before this window set was (at
        # startup, or a snapshot adding the focused window). That observation
        # is still valid: adopt it, as :window-opened does.
        (if (and os (= (st/locate acc os) (acc :current)))
          (-> acc
              (st/update-ws (acc :current) |(ws/focus-id $ os))
              (d/assoc {:external-focus false}))
          acc)))))

(defn- window-moved
  "-> [state effects]"
  [s id rect]
  (def p (st/placements s))
  (def model (if (and (valid-id? id) (valid-rect? rect)) (p id)))
  (cond
    (nil? model) [s []]
    (= rect model) [(d/assoc s {:misfit (d/without (get s :misfit {}) id)}) []]
    (let [entry (get-in s [:misfit id])
          n (if (and entry (= (entry :rect) model)) (entry :n) 0)]
      (if (>= n misfit-limit)
        [s []]
        [(d/assoc s {:misfit (d/assoc (get s :misfit {})
                                      {id {:rect model :n (+ n 1)}})})
         [[:place id model]]]))))

# ---- commands ----------------------------------------------------------

(defn- next-layout [w]
  (def ls layout/layouts)
  (def i (or (index-of (w :layout) ls) -1))
  (ws/set-layout w (ls (mod (+ i 1) (length ls)))))

# commands that only move focus or change layout parameters
(def- ws-commands
  {:focus-next ws/focus-next
   :focus-prev ws/focus-prev
   :focus-master ws/focus-master
   :inc-master ws/inc-master
   :dec-master ws/dec-master
   :expand |(ws/resize-master $ ratio-step)
   :shrink |(ws/resize-master $ (- ratio-step))
   :next-layout next-layout})

# commands that reorder windows: need a real focused window
(def- reorder-commands
  {:swap-next ws/swap-next
   :swap-prev ws/swap-prev
   :swap-master ws/swap-master
   :shift-master ws/shift-master})

(defn- toggle-float [s]
  (def id (st/focused s))
  (if (and id (actionable? s))
    (set-floating s id (not (st/floating? s id)))
    s))

(defn- reassert-focus
  "ADR 0009: one delayed retry of a :goto's focus. Only when the OS reports a
  different, ordinary managed window; never from an unmanaged window or a
  floating dialog; at most once (the pending note is consumed)."
  [s args]
  (def p (s :pending-focus))
  (def t (and p (p :target)))
  (def os (s :os-focus))
  (if (and (empty? args) t os
           (= (st/locate s t) (s :current))
           (not (external? s))
           (not (st/floating? s os))
           (not= os t))
    [(-> s (d/without :pending-focus) (st/update-current |(ws/focus-id $ t)))
     [[:focus t]]]
    [s []]))

(def- focus-moving? {:focus-next true :focus-prev true :focus-master true})

(def command-args
  "Every command the core understands -> what argument it takes
  (:none | :tag | :layout). The keymap validates bindings against this."
  (struct
    ;(mapcat |[$ :none]
              [;(keys ws-commands) ;(keys reorder-commands) :close :refresh])
    :goto :tag :send :tag :set-layout :layout :toggle-float :none
    :reassert-focus :internal))   # :internal = issued by the shell, never bound to a key

(defn- goto-tag [s tag]
  (-> s (d/assoc {:current tag :external-focus true}) (d/without :os-focus)))

(defn- send-focused
  "xmonad's `shift`: move the focused window to another workspace; the view
  stays where it is."
  [s tag]
  (def id (st/focused s))
  (if (and id (actionable? s) (valid-tag? s tag) (not= tag (s :current)))
    [(-> s
         (st/update-current |(ws/remove $ id))
         (st/update-ws tag |(ws/insert $ id)))
     [[:send id tag]]]
    [s []]))

(defn- explicit-focus [s]
  (if-let [f (st/focused s)] [[:focus f]] []))

# -> [state' explicit-effects]
(defn- command [s name args]
  (cond
    (ws-commands name)
    (let [s2 (st/update-current s (ws-commands name))]
      # an explicit focus command is the user asking for a :focus even while
      # focus is external (that is how they get back from a dialog)
      [s2 (if (focus-moving? name) (explicit-focus s2) [])])

    (reorder-commands name)
    [(if (actionable? s) (st/update-current s (reorder-commands name)) s) []]

    (= name :goto)
    (let [tag (get args 0)]
      (if (and (valid-tag? s tag) (not= tag (s :current)))
        (let [s2 (goto-tag s tag)
              f (st/focused s2)
              # remember what we want focused: a later :reassert-focus may
              # restore it if the OS/Jwno overrides us (ADR 0009 R-10)
              s3 (if f (d/assoc s2 {:pending-focus {:target f :tag tag}}) s2)]
          [s3 [[:goto tag] ;(explicit-focus s2)]])
        [s []]))

    (= name :toggle-float) [(toggle-float s) []]

    (= name :reassert-focus) (reassert-focus s args)

    (= name :send) (send-focused s (get args 0))

    (= name :close)
    [s (if (actionable? s) [[:close (st/focused s)]] [])]

    (= name :set-layout)
    (let [l (get args 0)]
      [(if (index-of l layout/layouts)
         (st/update-current s |(ws/set-layout $ l))
         s)
       []])

    [s []]))

# ---- effects -----------------------------------------------------------

(defn- all-places [s]
  (def p (st/placements s))
  (map |[:place $ (p $)] (st/tiled-ids s (st/current-ws s))))

(defn- derive-effects [old new silent?]
  (def old-p (st/placements old))
  (def new-w (st/current-ws new))
  (def new-p (st/placements new))
  (def effects @[])
  (each id (st/tiled-ids new new-w)
    (unless (= (old-p id) (new-p id))
      (array/push effects [:place id (new-p id)])))
  (def f (st/focused new))
  (when (and f (not silent?) (not (external? new))
             (or (not= f (st/focused old))
                 (not= (old :current) (new :current))))
    (array/push effects [:focus f]))
  effects)

(defn- order-effects
  "Everything else first, :focus last (place windows, then focus); no dupes."
  [fx]
  (def fx (distinct fx))
  (tuple ;(filter |(not= (first $) :focus) fx)
         ;(filter |(= (first $) :focus) fx)))

# ---- entry point -------------------------------------------------------

(defn- tail [xs] (if (empty? xs) [] (slice xs 1)))

(defn- settle-pending
  "Drop the pending :goto focus when it is stale (ADR 0009). A silent
  observation of a different window does NOT drop it: that is exactly the
  override we want to repair."
  [old s kind args]
  (def p (s :pending-focus))
  (cond
    (nil? p) s
    (or (nil? (st/locate s (p :target)))
        (not= (s :current) (p :tag))
        (and (= kind :focus-changed) (= (get args 0) (p :target)))
        # a decision the core itself just took (new window, close) wins
        (and (index-of kind [:window-opened :window-seen :window-closed])
             (not= (st/focused old) (st/focused s))))
    (d/without s :pending-focus)
    s))

(defn- update* [s0 event]
  (def kind (get event 0))
  (def args (tail event))
  # any command other than :reassert-focus is a new intent: forget the pending one
  (def s (if (and (= kind :command) (not= (get args 0) :reassert-focus))
           (d/without s0 :pending-focus)
           s0))
  (cond
    (and (= kind :command) (= (get args 0) :refresh))
    (let [s2 (d/without s :misfit)
          f (st/focused s2)]
      {:state s2
       :effects (tuple ;(all-places s2)
                       ;(if (and f (not (external? s2))) [[:focus f]] []))})

    (= kind :window-moved)
    (let [[s2 fx] (window-moved s (get args 0) (get args 1))]
      {:state s2 :effects (tuple ;fx)})

    (let [[s2 explicit silent?]
          (case kind
            :window-opened [(open-window s (get args 0) (get args 1)) [] false]
            :window-closed [(close-window s (get args 0)) [] false]
            :window-seen [(window-seen s (get args 0) (get args 1) (get args 2)) [] false]
            :focus-changed [(focus-window s (get args 0)) [] true]
            :desktop-changed [(desktop-changed s (get args 0)) [] true]
            :screen-changed [(if (valid-rect? (get args 0))
                               (d/assoc s {:screen (args 0)})
                               s)
                             [] false]
            :windows-observed [(windows-observed s (get args 0)) [] true]
            :command (let [[s* fx] (command s (get args 0) (tail args))]
                       [s* fx false])
            [s [] false])]
      (let [s3 (settle-pending s s2 kind args)]
        {:state s3
         :effects (order-effects [;explicit ;(derive-effects s s3 silent?)])}))))

(defn update [s event]
  (if (indexed? event) (update* s event) {:state s :effects []}))
