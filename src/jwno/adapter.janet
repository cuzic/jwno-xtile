# Jwno adapter, stage 1 (ADR 0010). Implements the runtime's `ctx` port on top of Jwno and
# turns Jwno's hooks into core events.
#
# It imports neither jw32 nor jwno/*: Jwno's `context` and an OS-call table `win32` are passed in
# (so Linux can load and test it with fakes). Everything about Jwno's API here was read from the
# source (Jwno 0.9.16). The contract tests (spike/run-contract.ps1) cover it on hosted Windows Server and, partly,
# on one real Windows 11 PC (docs/spike/2026-11-01-real-machine.md); what they do not cover is listed there.
#
# win32 (functions, all total or throwing only on programmer error):
#   :foreground-hwnd ()        -> hwnd|nil          GetForegroundWindow
#   :root-of (hwnd)            -> hwnd|nil          GetAncestor(GA_ROOT); nil for a dead window
#   :hwnd->number (hwnd)       -> int               pointer-to-number
#   :facts (hwnd)              -> facts             classify's facts (ADR 0008)
#   :desktop-guid (hwnd)       -> "{...}"|nil       IVirtualDesktopManager::GetWindowDesktopId (sync, no retry)
#   :minimized? (hwnd) :hung? (hwnd) -> bool
#   :beep ()
#   :swp-nomove-nosize         -> int               SWP_NOMOVE|SWP_NOSIZE
#
# opts: :tags :rules :poll-seconds (nil = off) :reassert? (default false) :log :spawn :later
#       :suppress-focus? (A, default true) :keymap :bindings
#
# Rules this file keeps (each is a review finding of ADR 0010):
#  * hooks only COPY values and hand the dispatch to `spawn`: Jwno keeps working after a hook
#    returns (add-child + transform, retile + set-focus), so a synchronous dispatch would be
#    overwritten (H1);
#  * every id given to the core goes through `norm` (integer, GA_ROOT, NULL -> nil) (M-A);
#  * no call into Jwno's vd-manager worker (it yields and retries for ~1.5s) from a hook or a port (M-B);
#  * workspaces are the WM's own (ADR 0006): a window of another workspace is PARKED off-screen, not
#    hidden, so it stays in the taskbar, in Jwno's tree and in `enumerate`; a window on another Windows
#    virtual desktop is simply not ours (only the current desktop is managed).

(import ../core/state :as st)
(import ../core/keymap :as km)
(import ../shell/runtime :as rt)

(def default-tags
  "WM workspaces (ADR 0006). They are groups inside the WM, independent of Windows' virtual desktops."
  (tuple "1" "2" "3" "4" "5" "6" "7" "8" "9"))

(def repark-limit 3)    # Opus M3: how often the poll parks the same window again before it gives up
(def park-x -32000)
(def park-y -32000)

(defn rect->jwno
  "Core {:x :y :w :h} -> Jwno {:left :top :right :bottom}. The right/bottom edges are exclusive."
  [r]
  {:left (r :x) :top (r :y) :right (+ (r :x) (r :w)) :bottom (+ (r :y) (r :h))})

(defn jwno->rect [r]
  {:x (r :left) :y (r :top) :w (- (r :right) (r :left)) :h (- (r :bottom) (r :top))})

(defn- install*
  [context win32 &opt opts]
  (default opts {})
  (def wm (in context :window-manager))
  (def hook-man (in context :hook-manager))
  (def vd-man (in context :virtual-desktop-manager))
  (def tags (get opts :tags default-tags))
  (def log-fn (get opts :log (fn [level msg] (eprintf "[xtile %s] %s" level msg))))
  (def spawn (get opts :spawn (fn [f] (ev/spawn (f)))))
  (def later (get opts :later (fn [d f] (ev/spawn (ev/sleep d) (f)))))
  (def poll-seconds (get opts :poll-seconds 2))
  (def swp (get win32 :swp-nomove-nosize))
  (def w (fn [name & args]
           (def f (get win32 name))
           (unless f (errorf "win32.%s is missing" name))
           (f ;args)))

  (var rtm nil)
  (defn dispatch! [ev] (rt/dispatch rtm ev))

  # ---- ids: Core ids are integers; Jwno hwnds are pointers --------------------------------
  (def num->hwnd @{})
  (def extras @{})   # id -> {:class :title}, read from UIA in the hook (jw32 has no GetClassName)
  (defn norm
    "pointer -> integer id, via GA_ROOT. nil for nil or a dead window (NULL would become 0)."
    [hwnd]
    (when hwnd
      (def root (w :root-of hwnd))
      (when root
        (def n (w :hwnd->number root))
        (when (not= 0 n)
          (put num->hwnd n root)
          n))))

  (defn on-current-desktop?
    "A window on another Windows virtual desktop is not ours. We ask Windows itself, per window:
    Jwno's `last-vd` is not comparable to a window's desktop id at start (contract test CT-3)."
    [hwnd]
    (def [ok here] (protect (w :on-current-desktop? hwnd)))
    (or (not ok) here))

  (defn window-of [id]
    (def hwnd (get num->hwnd id))
    (unless hwnd (errorf "unknown window id %q" id))
    (def win (:find-hwnd wm hwnd))
    (unless win (errorf "window %q is not managed by Jwno" id))
    # Opus M2: `num->hwnd` is only as fresh as the last poll. If the user has switched Windows virtual
    # desktops since, a focus on this window would make Windows switch BACK (an implicit desktop switch),
    # and a move would act on a window of another desktop: refuse; the runtime's recovery re-observes.
    (unless (on-current-desktop? hwnd) (errorf "window %q is on another virtual desktop" id))
    win)

  # ---- virtual desktops: only the current one is managed (ADR 0006 D-4) -------------------
  (defn desktops [&opt refresh]
    (def [ok ds] (protect (:get-all-desktops vd-man refresh)))
    (if ok ds @[]))

  # ---- parking: a window of another workspace is moved off-screen and remembered ----------
  (def parked @{})   # id -> {:rect where it was :at where we put it}; OS-boundary memory, not WM state

  # ---- ports ------------------------------------------------------------------------------
  (defn work-area []
    (def [monitors main-idx] (:enumerate-monitors wm))
    (jwno->rect (get-in monitors [main-idx :work-area])))

  (defn foreground [] (norm (w :foreground-hwnd)))

  (defn visible-rect [win] (jwno->rect (:get-rect win true)))

  (defn move-to
    [win rect]
    (:transform win (rect->jwno rect) @{:swp-flags 0} wm))

  (defn hide
    "ADR 0006: leave the visible workspace. Remember where the window was, then park it off-screen
    at its own size. A window that is already parked is parked again (a :refresh re-asserts it)."
    [id]
    (def win (window-of id))
    (def hwnd (get num->hwnd id))
    (if (w :minimized? hwnd)
      # not moved now (a minimised window has no real position); remember that it owes a park, so the poll
      # parks it as soon as it is restored (P-1: a restored window of a hidden workspace must not appear)
      (unless (get parked id) (put parked id {:pending true :hwnd hwnd}))
    (do
      (def prev (let [p (get parked id)] (when (and p (not (p :pending))) p)))
      (def rect (if prev (prev :rect) (visible-rect win)))
      # Opus/J3: Jwno's transform un-maximises a window; remember it was maximised and maximise it again on return
      (def zoomed (if prev (prev :zoomed) (w :zoomed? hwnd)))
      (def at {:x park-x :y park-y :w (rect :w) :h (rect :h)})
      (move-to win at)
      # Opus M6: Jwno swallows transform failures; read the result back. A window that stayed on screen is
      # retried by the poll (bounded, see `repark-limit`)
      (let [after (protect (visible-rect win))]
        (when (and (after 0) (> ((after 1) :x) (+ park-x 2000)))
          (log-fn :warn (string/format "hide: window %q is still on screen at %q after the park" id (after 1)))))
      (put parked id {:rect rect :at at :hwnd hwnd :zoomed zoomed :reparks (if prev (get prev :reparks 0) 0)}))))

  (defn unpark
    "Put a parked window back where it was (a tile is placed again right after; a float stays there).
    Opus H1: this must not depend on `num->hwnd` (the CURRENT desktop's windows only) or on Jwno's tree:
    the entry keeps the hwnd, and falls back to Jwno's tree-free `transform-hwnd`. The entry is dropped
    only after the move worked, or when the window is gone."
    [id]
    (when-let [p (get parked id)]
      (def hwnd (or (get num->hwnd id) (p :hwnd)))
      (cond
        (or (nil? hwnd) (nil? (w :root-of hwnd)) (p :pending))
        (put parked id nil)                       # gone, or never moved (it was minimised): nothing to bring back
        true
        (do
          (if-let [win (and (get num->hwnd id) (:find-hwnd wm hwnd))]
            (move-to win (p :rect))
            (:transform-hwnd wm hwnd (rect->jwno (p :rect)) @{:swp-flags 0}))
          (when (and (p :zoomed) (get win32 :maximize)) ((get win32 :maximize) hwnd))
          (put parked id nil)))))

  # ---- the sink window (ADR 0006 D-7b): holds the OS focus when the visible workspace is empty ----
  (var sink nil)
  (defn focus-sink!
    "-> true if the sink could be used (a refusal by the foreground lock is logged, not an error)."
    []
    (def mk (get win32 :make-focus-sink))
    (def ui (get context :ui-manager))
    (when (and mk ui)
      (unless sink (set sink (mk ui)))
      (def ok ((sink :front)))
      (unless ok
        (log-fn :info "focus-none: the sink window did not get the foreground (foreground lock?)"))
      true))
  (defn sink-number? [hwnd]
    (when-let [s sink n ((s :hwnd-number))]
      (= n (w :hwnd->number hwnd))))

  (defn front-on-screen?
    "ADR 0006 D-7f: is the front window one the user can see? (Only asked for reclaim effects.)
    Unknown means no: then the reclaim goes ahead."
    []
    (def pf (get win32 :window-rect))
    (def hwnd (w :foreground-hwnd))
    (def r (and pf hwnd (pf hwnd)))
    (and r (> (r :left) (+ park-x 2000))))

  (defn show
    "ADR 0006 D-6: the window enters the visible workspace. Parked: back to where it was. Not parked but
    found off-screen (the entry was lost, or the core forgot it): to the work area. Otherwise nothing."
    [id]
    (if (get parked id)
      (unpark id)
      (when-let [hwnd (get num->hwnd id)
                 win (:find-hwnd wm hwnd)
                 pf (get win32 :window-rect)
                 r (pf hwnd)]
        (when (and (< (r :left) (+ park-x 2000)) (not (w :minimized? hwnd)))
          (def wa (work-area))
          (log-fn :info (string/format "show: window %q found off-screen at %q, bringing it back" id r))
          (move-to win {:x (wa :x) :y (wa :y)
                        :w (min (- (r :right) (r :left)) (wa :w)) :h (min (- (r :bottom) (r :top)) (wa :h))})))))

  (defn place [id rect]
    (put parked id nil)         # being placed supersedes being parked
    (def win (window-of id))
    (:transform win (rect->jwno rect) @{:swp-flags 0} wm)
    # Jwno swallows transform failures: read the result back and, if it differs, hand the
    # truth to the core as an observation (its :misfit logic gives up after 3 tries).
    (def hwnd (get num->hwnd id))
    (unless (or (w :minimized? hwnd) (w :hung? hwnd))
      (def actual (jwno->rect (:get-rect win true)))
      (unless (= actual rect)
        (log-fn :debug (string/format "place mismatch id=%q want=%q actual=%q" id rect actual))
        (spawn (fn [] (dispatch! [:window-moved id actual]))))))

  (defn facts-of
    "Win32 facts plus what UIA told us when the window was created."
    [id hwnd]
    (table/to-struct (merge (w :facts hwnd) (get extras id {}))))

  (defn enumerate []
    (def fresh @{})
    (def out @[])
    (each win (:get-window-stack (in wm :root))
      (var step :start)
      (def [ok entry]
        (protect
          (let [hwnd (in win :hwnd)
                id (do (set step :norm) (norm hwnd))]
            (when id
              (set step :desktop-guid)
              (when (on-current-desktop? hwnd)
                (put fresh id (get num->hwnd id))
                (set step :facts)
                [id nil (facts-of id hwnd)])))))
      (if ok
        (when entry (array/push out entry))
        (log-fn :warn (string "enumerate: skipped a window (step " step ", hwnd " (in win :hwnd) "): " entry))))
    # replace, do not accumulate: windows whose :window-removed never came must not pile up
    (table/clear num->hwnd)
    (eachp [k v] fresh (put num->hwnd k v))
    (eachk id extras (unless (get fresh id) (put extras id nil)))
    out)

  (def ctx
    @{:place place
      :focus (fn [id &opt reclaim]
              (log-fn :debug (string/format "port-focus id=%q%s" id (if reclaim " (reclaim)" "")))
              (unless (and reclaim (front-on-screen?))      # D-7f: a reclaim never takes the focus from a window the user can see
                (unpark id)                       # a parked window cannot be focused usefully
                (:set-focus (window-of id) wm)))  # the WINDOW's :set-focus, never wm's (A-2)
      :focus-none (fn [&opt reclaim]
                    (log-fn :debug (string/format "port-focus-none%s" (if reclaim " (reclaim)" "")))
                    (cond
                      (and reclaim (front-on-screen?)) true
                      (focus-sink!) true
                      (do (log-fn :warn "focus-none: no sink window available: the focus stays where it is")
                          true)))
      :close (fn [id] (:close (window-of id)))
      :hide hide
      :show show
      :goto (fn [_] nil)            # hide/show do the work (ADR 0006 D-1); nothing to do at the OS level
      :send (fn [_ _] nil)
      :foreground foreground
      :foreground-is? (fn [id] (and id (= id (foreground))))
      :enumerate enumerate
      :work-area work-area
      :later later
      :log log-fn
      :notify (fn [kind id]
                (when (= kind :ignored-close) (w :beep))
                (log-fn :info (string "notify " kind " " id)))
      :reassert? (get opts :reassert? false)})   # R-10 answered a Jwno refocus after an OS desktop switch; :goto no longer causes one

  # ---- core state + runtime ---------------------------------------------------------------
  (set rtm (rt/make ctx (st/make (work-area) tags (get opts :rules []))))

  # ---- Jwno must not place windows itself (ADR 0010 D2) ------------------------------------
  (defn pin! [win] (put (in win :tags) :swp-flags swp))
  (defn pin-all! [] (each win (:get-all-windows (in wm :root)) (pin! win)))
  (pin-all!)

  # ---- A: swallow the one wm :set-focus that follows a virtual-desktop change (D7) --------
  (def suppress @{:on false})
  (def orig-set-focus (in wm :set-focus))
  (def orig-dnc (in wm :desktop-name-changed))
  (def set-focus* (fn [self & args]
                    (if (suppress :on)
                      (do (log-fn :debug "suppressed Jwno's post-desktop-switch set-focus") nil)
                      (orig-set-focus self ;args))))
  (def dnc* (fn [self & args]
              (put suppress :on true)
              (defer (put suppress :on false)
                (orig-dnc self ;args))))
  (var a-active? false)
  (when (get opts :suppress-focus? true)
    (put wm :set-focus set-focus*)
    (put wm :desktop-name-changed dnc*)
    (set a-active? (and (= (in wm :set-focus) set-focus*)
                        (= (in wm :desktop-name-changed) dnc*)))
    (unless a-active?
      (log-fn :warn "could not wrap Jwno's set-focus: falling back to the delayed re-assertion only")))

  # ---- filter: Jwno must not manage windows of other Windows virtual desktops at all --------
  # Jwno manages the window that has the focus at start (real run 3), and windows that open or get the focus
  # later, on ANY desktop (UNVERIFIED which of these reach it for other desktops); its transform un-maximises a window whatever
  # :swp-flags says (contract test CT-7b). Without this filter, starting the WM would restore the
  # maximised windows the user has on their other desktops. (This is not a tile/float/ignore decision:
  # that stays in the core, ADR 0010 M3.)
  (:add-hook hook-man :filter-window
             (fn [hwnd & _] (on-current-desktop? hwnd)))

  # ---- hooks: copy the values now, dispatch after Jwno has finished (D3, D5) --------------
  (:add-hook hook-man :window-created
             (fn [win uia-win _exe-path desktop-info]
               (pin! win)
               (def id (norm (in win :hwnd)))
               (when id
                 (def here? (on-current-desktop? (in win :hwnd)))
                 (log-fn :debug (string/format "window-created id=%q desktop-info=%q current-desktop=%q" id desktop-info here?))
                 (when here?
                   (put extras id
                        (table/to-struct
                          (merge (let [[ok c] (protect (:get_CachedClassName uia-win))] (if (and ok c) {:class c} {}))
                                 (let [[ok t] (protect (:get_CachedName uia-win))] (if (and ok t) {:title t} {})))))
                   (def facts (facts-of id (in win :hwnd)))
                   (def hwnd (in win :hwnd))
                   (spawn (fn []
                            # :window-created fires BEFORE Jwno looks for a frame, and a window with no
                            # frame (e.g. on a desktop that has no layout yet) is never added to the
                            # tree. Only tell the core about windows Jwno actually manages now.
                            (if (:find-hwnd wm hwnd)
                              (dispatch! [:window-seen id facts])
                              (log-fn :debug (string/format "window %q is not in Jwno's tree: not announced" id)))))))))

  (:add-hook hook-man :window-removed
             (fn [win]
               (def n (w :hwnd->number (in win :hwnd)))   # the window may already be dead: no GA_ROOT
               (put num->hwnd n nil)
               (put extras n nil)
               # ADR 0006 D-6 (Opus D6-M1): keep the entry while the window lives (an app hiding itself in the
               # tray is purged by Jwno and comes back to its parked position); a dead window loses it
               (when-let [p (get parked n)]
                 (when (or (nil? (p :hwnd)) (nil? (w :root-of (p :hwnd))))
                   (put parked n nil)))
               (spawn (fn [] (dispatch! [:window-closed n])))))

  (:add-hook hook-man :focus-changed
             (fn [hwnd]
               (def id (norm hwnd))
               (spawn (fn [] (dispatch! [:focus-changed id])))))

  # Windows' own virtual desktop changed: the managed windows are now another set (ADR 0006 D-4).
  (:add-hook hook-man :virtual-desktop-changed
             (fn [& _]
               (spawn (fn [] (dispatch! [:windows-observed (enumerate)])))))

  (:add-hook hook-man :monitor-updated
             (fn [top-frame]
               (def [ok wa] (protect (jwno->rect (get-in top-frame [:monitor :work-area]))))
               (def area (if (and ok wa) wa (work-area)))
               (spawn (fn []
                        (dispatch! [:screen-changed area])
                        (dispatch! [:command :refresh])))))

  # ---- user drags / resizes (ADR 0010 D9) ---------------------------------------------------
  (def drag-queue @[])
  (var move-hook nil)
  (var pump-failures 0)
  (var stopped false)

  (defn queue-drag
    "Runs INSIDE the message pump, nested in a C call: it must not yield, so it only appends to a
    plain array. Windows Jwno does not manage are not queued."
    [hwnd]
    (protect
      (when hwnd
        (def root (w :root-of hwnd))
        (when root
          (def n (w :hwnd->number root))
          (when (and (not= 0 n) (get num->hwnd n))
            (array/push drag-queue n))))))

  (defn drain-drags
    "Tell the core about the drags that ended, in OUR fiber (not in the callback). The rect is read
    now, not when the callback fired, so a snap that follows the drop is already in it."
    []
    (def ids (distinct drag-queue))
    (array/clear drag-queue)
    (each id ids
      (def [ok err]
        (protect
          (let [hwnd (get num->hwnd id)
                win (when hwnd (:find-hwnd wm hwnd))]
            (when (and win (not (w :minimized? hwnd)) (not (get parked id)))
              (def rect (visible-rect win))
              (log-fn :debug (string/format "window-dragged id=%q rect=%q" id rect))
              (dispatch! [:window-dragged id rect])))))
      (unless ok (log-fn :warn (string "window-dragged: " err)))))

  (defn unwatch! [why]
    (when move-hook
      (protect (w :unwatch-moves move-hook))
      (set move-hook nil)
      (log-fn :warn (string "stopped watching window moves: " why))))

  (defn pump-tick []
    (when (and move-hook (not stopped))
      (def [ok n] (protect (w :pump)))
      (if ok
        (do (set pump-failures 0)
            (when (> n 200) (log-fn :warn (string "the message pump handled " n " messages in one tick"))))
        (do (++ pump-failures)
            (when (>= pump-failures 10)
              (unwatch! (string "the pump failed 10 times, falling back to polling: " n))))))
    (drain-drags))

  (defn restore-parked
    "ADR 0006 H1: never leave a window off-screen behind us. Put every parked window back."
    []
    (each id (array ;(keys parked))
      (def [ok err] (protect (unpark id)))
      (unless ok (log-fn :warn (string "could not bring window " id " back: " err)))))

  (defn stop []
    (set stopped true)
    (restore-parked)
    (when sink (protect ((sink :destroy))) (set sink nil))
    (when move-hook
      (protect (w :unwatch-moves move-hook))
      (set move-hook nil)))

  (when (get opts :watch-moves? true)
    (def [ok hook] (protect (w :watch-moves queue-drag)))
    (if (and ok hook)
      (set move-hook hook)
      (log-fn :warn (string "could not watch window moves (polling only): " hook))))

  (:add-hook hook-man :shutting-down (fn [& _] (stop)))

  (defn schedule-pump []
    (when (and move-hook (not stopped))
      (later 0.1 (fn [] (protect (pump-tick)) (schedule-pump)))))

  # ---- polling: the only source for minimize / fullscreen / title / late removals (D4) -----
  (defn compare-placements
    "Read every managed window's visible frame and tell the core: it keeps the placement, floats
    a window the user maximised (D9 N3) and ignores floats. Not while a mouse button is down (the
    user may be dragging), not for minimised windows."
    []
    (unless (w :mouse-down?)
      (each [id hwnd] (array ;(pairs num->hwnd))
        (def [ok err]
          (protect
            (let [win (:find-hwnd wm hwnd)]
              (when (and win (not (w :minimized? hwnd)) (not (w :hung? hwnd)))
                (def rect (visible-rect win))
                (if-let [p (get parked id)]
                  (if (p :pending)
                    # it was minimised when its workspace was hidden and is on screen now: park it
                    (do (log-fn :debug (string/format "parking id=%q: restored from minimised on a hidden workspace" id))
                        (hide id))
                    # ours to keep parked: an app that moved itself back on-screen is parked again -- but not
                    # the window the user is working in, and not for ever (Opus M3): after `repark-limit`
                    # tries the entry is dropped, so we stop fighting an app (or user) that wants it on screen
                    (when (and (> (rect :x) (+ park-x 2000)) (not= id (foreground)))
                      (def n (get p :reparks 0))
                      (if (>= n repark-limit)
                        (do (log-fn :warn (string/format "giving up parking id=%q: it came back %d times" id n))
                            (put parked id nil))
                        (do (log-fn :debug (string/format "re-parking id=%q found at %q (try %d)" id rect (+ n 1)))
                            (move-to win (p :at))
                            (put parked id (struct ;(kvs p) :reparks (+ n 1)))))))
                (if (w :zoomed? hwnd)
                  (do
                    (log-fn :debug (string/format "compare: id=%q is maximised, rect=%q: floating it" id rect))
                    (dispatch! [:window-dragged id rect]))
                  (dispatch! [:window-moved id rect])))))))
        (unless ok (log-fn :warn (string "compare " id ": " err))))))

  (defn poll-once []
    (pump-tick)      # drops that are waiting must reach the core BEFORE the comparison below (N2)
    (pin-all!)
    (dispatch! [:windows-observed (enumerate)])
    (when (get opts :verify-placements? true) (compare-placements)))

  (defn schedule-poll []
    # not after stop: a timer that keeps re-arming itself keeps Janet's event loop (and so Jwno) alive
    (when (and poll-seconds (not stopped))
      (later poll-seconds (fn [] (unless stopped (protect (poll-once))) (schedule-poll)))))

  # ---- keys -------------------------------------------------------------------------------
  (defn jwno-key
    "Core's key names -> Jwno's (its key table is lower-case and spells Comma/Period as , and .)."
    [k]
    (def parts (string/split " + " k))
    (def last-part (last parts))
    (def mapped (case (string/ascii-lower last-part) "comma" "," "period" "." last-part))
    (string/join [;(slice parts 0 (- (length parts) 1)) mapped] " + "))

  (when-let [keymap (opts :keymap)]
    (:add-command (in context :command-manager) :xtile
                  (fn [& args]
                    # `jwno.exe -x ":xtile :goto 2"`: a workspace tag is a string in the core, but a bare
                    # number is much easier to type (and to quote) on a command line
                    (def [name & rest] args)
                    (def rest* (if (index-of name [:goto :send])
                                 (map |(if (number? $) (string $) $) rest)
                                 rest))
                    (dispatch! [:command name ;rest*])))
    (each b (get opts :bindings [])
      (def built (km/build [b] tags))
      (if (empty? (built :errors))
        (let [key (jwno-key (b 0))
              [ok err] (protect (:define-key keymap key [:xtile ;(slice (b 1) 1)]))]
          (unless ok (log-fn :warn (string "could not bind " key ": " err))))
        (log-fn :warn (string "binding rejected: " ;(built :errors))))))

  (defn top-level-hwnds
    "Every top-level window UI Automation knows (the desktop's children), as Jwno hwnds. Empty when
    there is no UIA manager (the fake world of the unit tests)."
    []
    (def uia (get context :uia-manager))
    (def found @[])
    (when uia
      (def [ok err]
        (protect
          (let [root (:get-root uia)
                walker (:create-raw-view-walker uia)
                cr (:create-cache-request uia @[30020])]   # UIA_NativeWindowHandlePropertyId
            (:enumerate-children uia root
                                 (fn [e]
                                   (def h (protect (:get_CachedNativeWindowHandle e)))
                                   (when (and (h 0) (h 1)) (array/push found (h 1)))
                                   true)
                                 walker cr)
            (:Release cr) (:Release walker) (:Release root))))
      (unless ok (log-fn :warn (string "top-level-hwnds: " err))))
    found)

  (defn adopt-existing!
    "Jwno itself only manages the window that has the focus when it starts, and windows opened later
    (real run 3: a window that existed before Jwno started was never managed). Offer every other
    top-level window of this desktop to Jwno's own path (its filters and hooks decide)."
    []
    (def wa (work-area))
    (def pf (get win32 :window-rect))
    (each hwnd (top-level-hwnds)
      (def [ok err]
        (protect
          (when (and (not (:find-hwnd (in wm :root) hwnd)) (on-current-desktop? hwnd) (not (sink-number? hwnd)))
            (cond
              # Opus M1 (a): Jwno's transform would un-maximise it before the core could classify it
              # (a maximised window is a float for the core): leave maximised windows alone
              (w :zoomed? hwnd)
              (log-fn :debug "adopt-existing: leaving a maximised window alone")
              # Opus M1 (e): the core has one monitor; a window whose centre is elsewhere is not ours
              (let [r (and pf (pf hwnd))]
                (and r (let [cx (div (+ (r :left) (r :right)) 2) cy (div (+ (r :top) (r :bottom)) 2)]
                         (or (< cx (wa :x)) (>= cx (+ (wa :x) (wa :w))) (< cy (wa :y)) (>= cy (+ (wa :y) (wa :h)))))))
              (log-fn :debug "adopt-existing: leaving a window of another monitor alone")
              (:window-opened wm hwnd)))))
      (unless ok (log-fn :debug (string "adopt-existing: " err)))))

  (defn recover-strays
    "A previous run may have died with windows parked off-screen: bring them back."
    []
    (def wa (work-area))
    # Opus H1/M7: also windows Jwno does not manage now (another desktop, rejected by its filter): go by
    # the OS, not by Jwno's tree. UNVERIFIED ON WINDOWS whether UIA lists other desktops' windows.
    (when (get win32 :window-rect)
      (each hwnd (top-level-hwnds)
        (def [ok err]
          (protect
            (let [r (w :window-rect hwnd)]
              (when (and r (< (r :left) (+ park-x 2000)) (not (w :minimized? hwnd)) (not (sink-number? hwnd)))
                (log-fn :info (string/format "recovering unmanaged window found off-screen at %q" r))
                (:transform-hwnd wm hwnd
                                 {:left (wa :x) :top (wa :y)
                                  :right (+ (wa :x) (min (- (r :right) (r :left)) (wa :w)))
                                  :bottom (+ (wa :y) (min (- (r :bottom) (r :top)) (wa :h)))}
                                 @{:swp-flags 0})))))
        (unless ok (log-fn :warn (string "recover (os scan): " err)))))
    (each win (:get-all-windows (in wm :root))
      (def [ok err]
        (protect
          (let [rect (visible-rect win)
                id (norm (in win :hwnd))]
            (when (and id (not (get parked id)) (< (rect :x) (+ park-x 2000)))
              (log-fn :info (string/format "recovering window %q found off-screen at %q" id rect))
              (move-to win {:x (wa :x) :y (wa :y) :w (min (rect :w) (wa :w)) :h (min (rect :h) (wa :h))})))))
      (unless ok (log-fn :warn (string "recover: " err)))))

  (defn start
    "Hooks are already registered (R-7): sync, then start polling."
    []
    (adopt-existing!)
    (when (> (length (desktops)) 1)
      (log-fn :warn "more than one Windows virtual desktop: only the current one is managed, and switching desktops resets the WM state of the windows (ADR 0006 D-4)"))
    (recover-strays)
    (rt/start rtm)
    (schedule-pump)
    (schedule-poll))

  @{:rt rtm :ctx ctx :start start :poll-once poll-once :enumerate enumerate :norm norm
    :a-active? a-active? :work-area work-area :parked parked
    :pump-tick pump-tick :stop stop :stopped? (fn [] stopped)})

(defn install
  "-> adapter table {:rt :start :poll-once :enumerate :norm :a-active? :ctx :pump-tick :stop :parked}.
  Idempotent: a second call on the same context returns the first adapter (it would otherwise
  wrap Jwno's methods and register every hook twice)."
  [context win32 &opt opts]
  (or (get context :xtile-adapter)
      (let [a (install* context win32 opts)]
        (put context :xtile-adapter a)
        a)))
