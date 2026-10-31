# Jwno adapter, stage 1 (ADR 0010). Implements the runtime's `ctx` port on top of Jwno and
# turns Jwno's hooks into core events.
#
# It imports neither jw32 nor jwno/*: Jwno's `context` and an OS-call table `win32` are passed in
# (so Linux can load and test it with fakes). Everything about Jwno's API here was read from the
# source (Jwno 0.9.16) and is UNVERIFIED ON WINDOWS until the contract tests exist.
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
# opts: :tags :rules :poll-seconds (nil = off) :reassert? :log :spawn :later
#       :suppress-focus? (A, default true) :keymap :bindings
#
# Rules this file keeps (each is a review finding of ADR 0010):
#  * hooks only COPY values and hand the dispatch to `spawn`: Jwno keeps working after a hook
#    returns (add-child + transform, retile + set-focus), so a synchronous dispatch would be
#    overwritten (H1);
#  * every id given to the core goes through `norm` (integer, GA_ROOT, NULL -> nil) (M-A);
#  * no call into Jwno's vd-manager worker (it yields and retries for ~1.5s) from a hook or a port (M-B);
#  * a window on a desktop we cannot map is never given to the core, and "unknown" (nil) is
#    kept for really-unknown only (N2).

(import ../core/state :as st)
(import ../core/keymap :as km)
(import ../shell/runtime :as rt)

(def default-tags
  "Workspace 1..9 = virtual desktop 1..9; \"0\" is reserved: nothing is ever placed there, so
  being on a desktop we cannot map shows the core an empty workspace."
  (tuple "1" "2" "3" "4" "5" "6" "7" "8" "9" "0"))

(defn rect->jwno
  "Core {:x :y :w :h} -> Jwno {:left :top :right :bottom}. The right/bottom edges are exclusive."
  [r]
  {:left (r :x) :top (r :y) :right (+ (r :x) (r :w)) :bottom (+ (r :y) (r :h))})

(defn jwno->rect [r]
  {:x (r :left) :y (r :top) :w (- (r :right) (r :left)) :h (- (r :bottom) (r :top))})

(defn install
  "-> adapter table {:rt :start :poll-once :enumerate :norm :tag-of-guid :a-active? :ctx}."
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

  (defn window-of [id]
    (def hwnd (get num->hwnd id))
    (unless hwnd (errorf "unknown window id %q" id))
    (def win (:find-hwnd wm hwnd))
    (unless win (errorf "window %q is not managed by Jwno" id))
    win)

  # ---- virtual desktop <-> tag (read-only; ADR 0010 D8) ----------------------------------
  (defn desktops [&opt refresh]
    (def [ok ds] (protect (:get-all-desktops vd-man refresh)))
    (if ok ds @[]))

  (defn tag-of-guid
    "guid -> tag | :unmappable | nil (no guid: really unknown)."
    [guid]
    (when guid
      (def want (string/ascii-upper (string guid)))
      (defn find-in [ds]
        (find |(= want (string/ascii-upper (string ($ 1)))) ds))
      (def ds (desktops))
      (if (empty? ds)
        "1"   # no desktop was ever created: the one default desktop
        (let [hit (or (find-in ds) (find-in (desktops true)))
              tag (and hit (string (hit 0)))]
          (if (and tag (index-of tag tags)) tag :unmappable)))))

  (defn tag-for-event
    "like tag-of-guid, but an unmappable desktop means the reserved empty workspace."
    [guid]
    (def t (tag-of-guid guid))
    (if (= t :unmappable) "0" t))

  # ---- ports ------------------------------------------------------------------------------
  (defn work-area []
    (def [monitors main-idx] (:enumerate-monitors wm))
    (jwno->rect (get-in monitors [main-idx :work-area])))

  (defn foreground [] (norm (w :foreground-hwnd)))

  (defn place [id rect]
    (def win (window-of id))
    (:transform win (rect->jwno rect) @{:swp-flags 0} wm)
    # Jwno swallows transform failures: read the result back and, if it differs, hand the
    # truth to the core as an observation (its :misfit logic gives up after 3 tries).
    (def hwnd (get num->hwnd id))
    (unless (or (w :minimized? hwnd) (w :hung? hwnd))
      (def actual (jwno->rect (:get-rect win true)))
      (unless (= actual rect)
        (spawn (fn [] (dispatch! [:window-moved id actual]))))))

  (defn enumerate []
    (def fresh @{})
    (def out @[])
    (each win (:get-window-stack (in wm :root))
      (def [ok entry]
        (protect
          (let [hwnd (in win :hwnd)
                id (norm hwnd)]
            (when id
              (def tag (tag-of-guid (w :desktop-guid hwnd)))
              (unless (= tag :unmappable)
                (put fresh id (get num->hwnd id))
                [id tag (w :facts hwnd)])))))
      (if ok
        (when entry (array/push out entry))
        (log-fn :warn (string "enumerate: skipped a window: " entry))))
    # replace, do not accumulate: windows whose :window-removed never came must not pile up
    (table/clear num->hwnd)
    (eachp [k v] fresh (put num->hwnd k v))
    out)

  (def ctx
    @{:place place
      :focus (fn [id] (:set-focus (window-of id) wm))   # the WINDOW's :set-focus, never wm's (A-2)
      :close (fn [id] (:close (window-of id)))
      :goto (fn [_] (error "goto is not supported in stage 1"))
      :send (fn [_ _] (error "send is not supported in stage 1"))
      :foreground foreground
      :foreground-is? (fn [id] (and id (= id (foreground))))
      :enumerate enumerate
      :work-area work-area
      :current-desktop (fn [] (tag-for-event (in wm :last-vd)))
      :later later
      :log log-fn
      :notify (fn [kind id]
                (when (= kind :ignored-close) (w :beep))
                (log-fn :info (string "notify " kind " " id)))
      :reassert? (get opts :reassert? true)})

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

  # ---- hooks: copy the values now, dispatch after Jwno has finished (D3, D5) --------------
  (:add-hook hook-man :window-created
             (fn [win _uia-win _exe-path desktop-info]
               (pin! win)
               (def id (norm (in win :hwnd)))
               (when id
                 (def tag (when desktop-info (tag-of-guid (in desktop-info :id))))
                 (unless (= tag :unmappable)
                   (def facts (w :facts (in win :hwnd)))
                   (spawn (fn [] (dispatch! [:window-seen id facts tag])))))))

  (:add-hook hook-man :window-removed
             (fn [win]
               (def n (w :hwnd->number (in win :hwnd)))   # the window may already be dead: no GA_ROOT
               (put num->hwnd n nil)
               (spawn (fn [] (dispatch! [:window-closed n])))))

  (:add-hook hook-man :focus-changed
             (fn [hwnd]
               (def id (norm hwnd))
               (spawn (fn [] (dispatch! [:focus-changed id])))))

  (:add-hook hook-man :virtual-desktop-changed
             (fn [guid & _]
               (def tag (tag-for-event guid))
               (when tag (spawn (fn [] (dispatch! [:desktop-changed tag]))))))

  (:add-hook hook-man :monitor-updated
             (fn [top-frame]
               (def [ok wa] (protect (jwno->rect (get-in top-frame [:monitor :work-area]))))
               (def area (if (and ok wa) wa (work-area)))
               (spawn (fn []
                        (dispatch! [:screen-changed area])
                        (dispatch! [:command :refresh])))))

  # ---- polling: the only source for minimize / fullscreen / title / late removals (D4) -----
  (defn poll-once []
    (pin-all!)
    (dispatch! [:windows-observed (enumerate)]))

  (defn schedule-poll []
    (when poll-seconds
      (later poll-seconds (fn [] (protect (poll-once)) (schedule-poll)))))

  # ---- keys -------------------------------------------------------------------------------
  (when-let [keymap (opts :keymap)]
    (:add-command (in context :command-manager) :xtile
                  (fn [& args] (dispatch! [:command ;args])))
    (each b (get opts :bindings [])
      (def built (km/build [b] tags))
      (if (empty? (built :errors))
        (:define-key keymap (b 0) [:xtile ;(slice (b 1) 1)])
        (log-fn :warn (string "binding rejected: " ;(built :errors))))))

  (defn start
    "Hooks are already registered (R-7): sync, then start polling."
    []
    (rt/start rtm)
    (schedule-poll))

  @{:rt rtm :ctx ctx :start start :poll-once poll-once :enumerate enumerate :norm norm
    :tag-of-guid tag-of-guid :a-active? a-active? :work-area work-area})
