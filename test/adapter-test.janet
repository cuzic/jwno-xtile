# Jwno adapter, stage 1 (ADR 0010), against a fake Jwno context and a fake win32.
# The fakes are OUR reading of Jwno's source: nothing here is verified on Windows.
(use ./t)
(import ../src/core/state :as st)
(import ../src/jwno/adapter :as ad)
(import ../src/shell/runtime :as rt)

# ---- fakes -------------------------------------------------------------------------------
# A "hwnd" is a pointer-like struct {:ptr n}, never a number: any place that forgets to convert
# it will be ignored by the core (valid-id? rejects structs) and the tests below will notice.
(defn hw [n] {:ptr n})

(defn fake-world []
  (def w @{:calls @[] :pending @[] :later @[] :logs @[]
           :windows @{}          # ptr -> window object
           :order @[]            # z-order, front first (ptrs)
           :fg nil               # foreground hwnd (struct) or nil
           :roots @{}            # ptr -> root ptr (default: itself)
           :guids @{}            # ptr -> desktop guid
           :desktop nil :minimized @{} :hung @{} :refuse @{} :zoomed @{} :mouse false :move-events @[] :move-cb nil :pump-throws false
           :rects @{}            # ptr -> actual visible rect after a transform (default: as asked)
           :desktops @[]         # [index guid name]
           :refreshes 0
           :last-vd nil
           :hooks @{}})
  (defn rec [& c] (array/push (w :calls) c))

  (def win-proto
    @{:transform (fn [self rect tags wm]
                   (rec :transform ((self :hwnd) :ptr) rect (merge (self :tags) tags))
                   # an app that REFUSES keeps its rect (set (w :refuse) ptr); otherwise the move happens
                   (unless (get (w :refuse) ((self :hwnd) :ptr))
                     (put (w :rects) ((self :hwnd) :ptr)
                          {:left (rect :left) :top (rect :top) :right (rect :right) :bottom (rect :bottom)})))
      :get-rect (fn [self no-frame]
                  (or (get (w :rects) ((self :hwnd) :ptr)) {:left 0 :top 0 :right 1 :bottom 1}))
      :set-focus (fn [self wm] (rec :window-set-focus ((self :hwnd) :ptr)) (put w :fg (self :hwnd)))
      :close (fn [self] (rec :close ((self :hwnd) :ptr)))})
  (defn add-window! [n &opt guid]
    (def win (table/setproto @{:hwnd (hw n) :tags @{}} win-proto))
    (put (w :windows) n win)
    (array/push (w :order) n)
    (when guid (put (w :guids) n guid))
    win)

  (def root
    @{:find-hwnd (fn [self hwnd] ((w :windows) (hwnd :ptr)))
      :get-window-stack (fn [self] (map |((w :windows) $) (w :order)))
      :get-all-windows (fn [self] (values (w :windows)))})
  (def wm-proto
    @{:find-hwnd (fn [self hwnd] ((w :windows) (hwnd :ptr)))
      :enumerate-monitors (fn [self] [[{:work-area {:left 0 :top 0 :right 1000 :bottom 600}}] 0])
      :set-focus (fn [self node] (rec :wm-set-focus node))
      :transform-hwnd (fn [self hwnd rect &opt tags]
                        (rec :transform-hwnd (hwnd :ptr) rect)
                        (unless (get (w :refuse) (hwnd :ptr))
                          (put (w :rects) (hwnd :ptr)
                               {:left (rect :left) :top (rect :top) :right (rect :right) :bottom (rect :bottom)})))
      :window-opened (fn [self hwnd] (rec :window-opened (hwnd :ptr)) ((w :add-window!) (hwnd :ptr)))
      :desktop-name-changed (fn [self name]
                              (rec :dnc name)
                              (when (w :dnc-throws) (error "boom"))
                              (:set-focus self :layout))})
  (def wm (table/setproto @{:root root} wm-proto))
  (put wm :last-vd (w :last-vd))
  (def hook-man
    @{:add-hook (fn [self name f] (put (w :hooks) name f))})
  (def vd-man
    @{:get-all-desktops (fn [self &opt refresh]
                          (when refresh (++ (w :refreshes)))
                          (w :desktops))})
  (def keymap @{:define-key (fn [self k cmd] (rec :define-key k cmd))})
  (def uia-man
    @{:get-root (fn [self] @{:Release (fn [_] nil)})
      :create-raw-view-walker (fn [self] @{:Release (fn [_] nil)})
      :create-cache-request (fn [self props] @{:Release (fn [_] nil)})
      :enumerate-children (fn [self root f walker cr]
                            (each n (w :top) (unless (f @{:get_CachedNativeWindowHandle (fn [_] (hw n))}) (break))))})
  (put w :top @[])
  (def cmd-man @{:add-command (fn [self name f] (put w :xtile-command f))})
  (put w :wm wm)
  (put w :context @{:window-manager wm :hook-manager hook-man :virtual-desktop-manager vd-man
                    :command-manager cmd-man :uia-manager uia-man})
  (put w :keymap keymap)
  (put w :win32
       {:foreground-hwnd (fn [] (w :fg))
        :root-of (fn [h] (def p (h :ptr))
                   (def r (get (w :roots) p p))
                   (if (= r :dead) nil (hw r)))
        :hwnd->number (fn [h] (h :ptr))
        :facts (fn [h] {:class "K" :visible? true :exe (string "a" (h :ptr) ".exe")})
        :desktop-guid (fn [h] (get (w :guids) (h :ptr)))
        :on-current-desktop? (fn [h]
                               (def g (get (w :guids) (h :ptr)))
                               (or (nil? (w :desktop)) (nil? g) (= (w :desktop) g)))
        :minimized? (fn [h] (truthy? (get (w :minimized) (h :ptr))))
        :hung? (fn [h] (truthy? (get (w :hung) (h :ptr))))
        :window-rect (fn [h] (get (w :rects) (h :ptr)))
        :beep (fn [] (rec :beep))
        :zoomed? (fn [h] (truthy? (get (w :zoomed) (h :ptr))))
        :mouse-down? (fn [] (w :mouse))
        :watch-moves (fn [cb] (put w :move-cb cb) (rec :watch-moves) :hook)
        :unwatch-moves (fn [hook] (put w :move-cb nil) (rec :unwatch-moves hook))
        :pump (fn []
                (when (w :pump-throws) (error "pump failed"))
                (def evs (array ;(w :move-events)))
                (array/clear (w :move-events))
                (each h evs ((w :move-cb) h))
                (length evs))
        :swp-nomove-nosize 3})
  (put w :add-window! add-window!)
  w)

(defn install-adapter [w &opt extra]
  (ad/install (w :context) (w :win32)
              (merge {:spawn (fn [f] (array/push (w :pending) f))
                      :later (fn [d f] (array/push (w :later) [d f]))
                      :log (fn [l m] (array/push (w :logs) [l m]))
                      :poll-seconds 2}
                     (or extra {}))))

(defn flush!
  "Run what the hooks handed to `spawn`: this is 'after Jwno returned'."
  [w]
  (while (not (empty? (w :pending)))
    (def f (first (w :pending)))
    (array/remove (w :pending) 0)
    (f)))

(def g1 "{AAAAAAAA-0000-0000-0000-000000000001}")
(def g2 "{AAAAAAAA-0000-0000-0000-000000000002}")

(defn state-of [a] (rt/state (a :rt)))

(defn calls-of [w kind] (filter |(= (first $) kind) (w :calls)))

# ---- tests -------------------------------------------------------------------------------

(deftest "install pins every existing window, so Jwno itself never moves it (swp-flags)"
  (def w (fake-world))
  (def win ((w :add-window!) 5))
  (install-adapter w)
  (is= 3 ((win :tags) :swp-flags)))

(deftest "window-created: pins the window in the hook, dispatches only after the hook returns"
  (def w (fake-world))
  (def a (install-adapter w))
  (def win ((w :add-window!) 7 g1))
  ((get (w :hooks) :window-created) win :uia "C:\\a.exe" {:id g1 :name :default})
  (is= 3 ((win :tags) :swp-flags))                # synchronous, before Jwno's own transform
  (is (nil? (st/locate (state-of a) 7)))          # the core has not heard of it yet
  (flush! w)
  (is= "1" (st/locate (state-of a) 7)))           # integer id, tag from the desktop

(deftest "ADR 0006 D-4: a window on another Windows virtual desktop is not given to the core"
  (def w (fake-world))
  (put w :desktop g1)                         # we are on desktop 1
  (def a (install-adapter w))
  (def here ((w :add-window!) 7 g1))
  (def there ((w :add-window!) 8 g2))
  ((get (w :hooks) :window-created) here :uia "x" {:id g1})
  ((get (w :hooks) :window-created) there :uia "x" {:id g2})
  (flush! w)
  (is= "1" (st/locate (state-of a) 7))
  (is (nil? (st/locate (state-of a) 8)))
  (is= [7] (tuple ;(map first ((a :enumerate))))))

(deftest "ADR 0006 D-4: with no virtual desktop ever created, every window is ours"
  (def w (fake-world))                               # :last-vd stays nil
  (def a (install-adapter w))
  (def win ((w :add-window!) 7 g2))
  ((get (w :hooks) :window-created) win :uia "x" {:id g2})
  ((get (w :hooks) :window-created) ((w :add-window!) 8) :uia "x" nil)   # no desktop info at all
  (flush! w)
  (is= "1" (st/locate (state-of a) 7))
  (is= "1" (st/locate (state-of a) 8)))

(deftest "ids: pointer-like hwnds become integers, GA_ROOT is applied, dead windows become nil"
  (def w (fake-world))
  (def a (install-adapter w))
  (put (w :roots) 9 4)                            # 9 is a child; its root is 4
  (is= 4 ((a :norm) (hw 9)))
  (put (w :roots) 10 :dead)
  (is (nil? ((a :norm) (hw 10))))
  (put (w :roots) 11 0)                           # GetAncestor on a dead hwnd gives NULL = pointer 0
  (is (nil? ((a :norm) (hw 11))))                 # ... which must not become the valid-looking id 0
  (is (nil? ((a :norm) nil))))

(deftest "focus-changed is normalised the same way as :foreground, nil passes through"
  (def w (fake-world))
  (def a (install-adapter w))
  (def win ((w :add-window!) 4 g1))
  ((get (w :hooks) :window-created) win :uia "x" {:id g1})
  (flush! w)
  (put (w :roots) 9 4)
  ((get (w :hooks) :focus-changed) (hw 9))
  (flush! w)
  (is= 4 ((state-of a) :os-focus))
  ((get (w :hooks) :focus-changed) nil)
  (flush! w)
  (is (nil? ((state-of a) :os-focus)))
  (is ((state-of a) :external-focus)))

(deftest "window-removed closes the window in the core and forgets the id"
  (def w (fake-world))
  (def a (install-adapter w))
  (def win ((w :add-window!) 4 g1))
  ((get (w :hooks) :window-created) win :uia "x" {:id g1})
  (flush! w)
  ((get (w :hooks) :window-removed) win)
  (flush! w)
  (is (nil? (st/locate (state-of a) 4)))
  (is (not (first (protect ((get (a :ctx) :place) 4 {:x 0 :y 0 :w 1 :h 1}))))))   # the id is forgotten

(deftest "place: exclusive right/bottom, overrides the swp-flags for this call only, and reads back"
  (def w (fake-world))
  (def a (install-adapter w))
  (def win ((w :add-window!) 4 g1))
  ((get (w :hooks) :window-created) win :uia "x" {:id g1})
  (flush! w)
  (array/clear (w :calls))
  ((get (a :ctx) :place) 4 {:x 10 :y 20 :w 300 :h 200})
  (def [_ ptr rect tags] (first (calls-of w :transform)))
  (is= {:left 10 :top 20 :right 310 :bottom 220} rect)
  (is= 0 (tags :swp-flags))                       # this call really moves ...
  (is= 3 ((win :tags) :swp-flags))                # ... the window itself stays pinned
  (flush! w)
  (is= 0 (length (w :pending))))

(deftest "place: a different result is reported to the core as a window-moved observation, not thrown"
  (def w (fake-world))
  (def a (install-adapter w))
  (def win ((w :add-window!) 4 g1))
  ((get (w :hooks) :window-created) win :uia "x" {:id g1})
  (flush! w)
  (put (w :refuse) 4 true)
  (put (w :rects) 4 {:left 0 :top 0 :right 100 :bottom 50})   # the app refused the size
  ((get (a :ctx) :place) 4 {:x 10 :y 20 :w 300 :h 200})
  (is= 1 (length (w :pending)))
  (put (w :minimized) 4 true)
  ((get (a :ctx) :place) 4 {:x 10 :y 20 :w 300 :h 200})       # minimized: Jwno skips it; no read-back
  (is= 1 (length (w :pending))))

(deftest "place / focus / close on an unknown or unmanaged window throw (a ghost), nothing else does"
  (def w (fake-world))
  (def a (install-adapter w))
  (is (not (first (protect ((get (a :ctx) :place) 99 {:x 0 :y 0 :w 1 :h 1})))))
  (is (not (first (protect ((get (a :ctx) :focus) 99)))))
  # goto / send are no-ops at the OS level now (hide/show do the work)
  (is (first (protect ((get (a :ctx) :goto) "2"))))
  (is (first (protect ((get (a :ctx) :send) 4 "2")))))

(deftest "focus uses the WINDOW's set-focus, never wm's (which A suppresses)"
  (def w (fake-world))
  (def a (install-adapter w))
  (def win ((w :add-window!) 4 g1))
  ((get (w :hooks) :window-created) win :uia "x" {:id g1})
  (flush! w)
  (array/clear (w :calls))
  ((get (a :ctx) :focus) 4)
  (is= [[:window-set-focus 4]] (tuple ;(calls-of w :window-set-focus)))
  (is= 0 (length (calls-of w :wm-set-focus)))
  ((get (a :ctx) :close) 4)
  (is= [[:close 4]] (tuple ;(calls-of w :close))))

(deftest ":foreground-is? is an exact match on the normalised foreground"
  (def w (fake-world))
  (def a (install-adapter w))
  (put w :fg (hw 4))
  (is ((get (a :ctx) :foreground-is?) 4))
  (is (not ((get (a :ctx) :foreground-is?) 5)))
  (put w :fg nil)
  (is (not ((get (a :ctx) :foreground-is?) 4))))

(deftest "A: only the set-focus INSIDE desktop-name-changed is swallowed; it is released even on error"
  (def w (fake-world))
  (def a (install-adapter w))
  (is (a :a-active?))
  (def wm (w :wm))
  (:desktop-name-changed wm "Desktop 2")
  (is= 0 (length (calls-of w :wm-set-focus)))     # swallowed
  (:set-focus wm :node)                            # an ordinary call (e.g. a Jwno command)
  (is= 1 (length (calls-of w :wm-set-focus)))
  (put w :dnc-throws true)
  (is (not (first (protect (:desktop-name-changed wm "x")))))
  (:set-focus wm :node)
  (is= 2 (length (calls-of w :wm-set-focus))))    # not stuck in "suppressed"

(deftest "A can be switched off"
  (def w (fake-world))
  (def a (install-adapter w {:suppress-focus? false}))
  (is (not (a :a-active?)))
  (:desktop-name-changed (w :wm) "x")
  (is= 1 (length (calls-of w :wm-set-focus))))

(deftest "virtual-desktop-changed: the managed set is re-synced to the new desktop (the old one's windows leave)"
  (def w (fake-world))
  (put w :desktop g1)
  (def a (install-adapter w))
  (def on1 ((w :add-window!) 4 g1))
  ((get (w :hooks) :window-created) on1 :uia "x" {:id g1})
  (flush! w)
  (is= "1" (st/locate (state-of a) 4))
  # the user moves to desktop 2, where window 5 lives
  (put w :desktop g2)
  ((w :add-window!) 5 g2)
  ((get (w :hooks) :virtual-desktop-changed) g2 "Desktop 2" nil)
  (flush! w)
  (is (nil? (st/locate (state-of a) 4)))
  (is= "1" (st/locate (state-of a) 5)))

(deftest "start: observes the existing windows, warns about several desktops, and schedules the poll"
  (def w (fake-world))
  (put w :desktops @[[1 g1 nil] [2 g2 nil]])
  (put w :desktop g2)
  ((w :add-window!) 4 g2)
  ((w :add-window!) 5 g1)
  (def a (install-adapter w))
  ((a :start))
  (is= "1" (st/locate (state-of a) 4))
  (is (nil? (st/locate (state-of a) 5)))              # on the other desktop
  (is (find |(string/find "more than one Windows virtual desktop" (string ($ 1))) (w :logs)))
  (is (find |(= 2 (first $)) (w :later))))

(deftest "poll: re-pins windows, replaces the snapshot, removes ghosts, keeps polling"
  (def w (fake-world))
  (def a (install-adapter w))
  (def win ((w :add-window!) 4 g1))
  ((get (w :hooks) :window-created) win :uia "x" {:id g1})
  (flush! w)
  (put (win :tags) :swp-flags nil)                # e.g. layout-history cleared the tags
  (put (w :windows) 4 nil)                        # the window died; its :window-removed never came
  (array/clear (w :order))
  ((a :poll-once))
  (is (nil? (st/locate (state-of a) 4)))
  (def w2 (fake-world))
  (def a2 (install-adapter w2))
  (def win2 ((w2 :add-window!) 5 g1))
  (put (win2 :tags) :swp-flags nil)
  ((a2 :poll-once))
  (is= 3 ((win2 :tags) :swp-flags))
  (is= "1" (st/locate (state-of a2) 5)))

(deftest "enumerate: front-to-back order, one broken window does not spoil the snapshot"
  (def w (fake-world))
  (def a (install-adapter w))
  ((w :add-window!) 1 g1)
  ((w :add-window!) 2 g1)
  ((w :add-window!) 3 g1)
  (put (w :roots) 2 :dead)                         # norm -> nil: skipped
  (def snap ((a :enumerate)))
  (is= [1 3] (tuple ;(map first snap)))
  (is (nil? ((first snap) 1)))                       # the tag is the core's business (ADR 0006)
  # a window on another virtual desktop is left out of the snapshot
  (put w :desktop g1)
  ((w :add-window!) 4 g2)
  (is= [1 3] (tuple ;(map first ((a :enumerate))))))

(deftest "monitor-updated re-asserts the core's placement instead of fighting Jwno's retile"
  (def w (fake-world))
  (def a (install-adapter w))
  (def win ((w :add-window!) 4 g1))
  ((get (w :hooks) :window-created) win :uia "x" {:id g1})
  (flush! w)
  (array/clear (w :calls))
  ((get (w :hooks) :monitor-updated) {:monitor {:work-area {:left 0 :top 0 :right 500 :bottom 400}}})
  (is= 0 (length (calls-of w :transform)))        # nothing runs inside the hook
  (flush! w)
  (is= {:x 0 :y 0 :w 500 :h 400} ((state-of a) :screen))
  (def [_ _ rect _] (last (calls-of w :transform)))
  (is= {:left 0 :top 0 :right 500 :bottom 400} rect))

(deftest "key bindings: valid ones become Jwno commands, invalid ones are rejected with a log"
  (def w (fake-world))
  (def a (install-adapter w {:keymap (w :keymap)
                             :bindings [["Alt + J" [:command :focus-next]]
                                        ["Alt + 1" [:command :goto "1"]]
                                        ["Alt + X" [:command :nope]]]}))
  (is= [["Alt + J" [:xtile :focus-next]] ["Alt + 1" [:xtile :goto "1"]]]
       (tuple ;(map |(tuple ($ 1) ($ 2)) (calls-of w :define-key))))
  (is (find |(string/find "rejected" (string ($ 1))) (w :logs)))
  ((w :xtile-command) :focus-next)                # runs the core command
  (is a))

(deftest "class and title come from the hook's UIA element (jw32 has no GetClassName) and are remembered for the poll"
  (def w (fake-world))
  (def a (install-adapter w {:rules [{:match {:class "#32770"} :action :float}]}))
  (def win ((w :add-window!) 4 g1))
  (def uia @{:get_CachedClassName (fn [self] "#32770") :get_CachedName (fn [self] "Save As")})
  ((get (w :hooks) :window-created) win uia "x" {:id g1})
  (flush! w)
  (is (st/floating? (state-of a) 4))                 # classified by the class we read from UIA
  (def snap ((a :enumerate)))
  (is= "#32770" (((first snap) 2) :class))           # the poll does not lose it
  (is= "Save As" (((first snap) 2) :title))
  # a broken UIA element must not stop the window from being managed
  (def win2 ((w :add-window!) 5 g1))
  ((get (w :hooks) :window-created) win2 :not-an-element "x" {:id g1})
  (flush! w)
  (is= "1" (st/locate (state-of a) 5)))

(deftest "key bindings: Core's key names are translated to Jwno's, and one bad key does not stop the rest"
  (def w (fake-world))
  (def a (install-adapter w {:keymap (w :keymap)
                             :bindings [["Alt + Comma" [:command :inc-master]]
                                        ["Alt + Shift + Period" [:command :dec-master]]
                                        ["Alt + J" [:command :focus-next]]]}))
  (is= ["Alt + ," "Alt + Shift + ." "Alt + J"] (tuple ;(map |($ 1) (calls-of w :define-key))))
  # Jwno refusing a key must be survivable
  (def w2 (fake-world))
  (put (w2 :keymap) :define-key (fn [self k cmd] (when (string/find "," k) (error "unknown key name")) (array/push (w2 :calls) [:define-key k cmd])))
  (def a2 (install-adapter w2 {:keymap (w2 :keymap)
                               :bindings [["Alt + Comma" [:command :inc-master]]
                                          ["Alt + J" [:command :focus-next]]]}))
  (is= ["Alt + J"] (tuple ;(map |($ 1) (calls-of w2 :define-key))))
  (is (find |(string/find "could not bind" (string ($ 1))) (w2 :logs))))

(deftest "a window Jwno did not add to its tree (no frame) is not announced to the core"
  (def w (fake-world))
  (def a (install-adapter w))
  (def orphan (table/setproto @{:hwnd (hw 8) :tags @{}} @{}))   # not registered: find-hwnd -> nil
  ((get (w :hooks) :window-created) orphan :uia "x" {:id g1})
  (flush! w)
  (is (nil? (st/locate (state-of a) 8)))
  (is (find |(string/find "not in Jwno's tree" (string ($ 1))) (w :logs))))

# ---- D9: window-dragged / window-moved ---------------------------------------------------

(defn managed-window
  "a window known to the core, tiled, id n"
  [w a n]
  (def win ((w :add-window!) n g1))
  ((get (w :hooks) :window-created) win :uia "x" {:id g1})
  (flush! w)
  win)

(defn pump-tick! [a] ((a :pump-tick)))

(deftest "D9: the MOVESIZEEND callback only queues; the dispatch happens in our own fiber, with the rect read then"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (managed-window w a 5)
  (is (w :move-cb))
  (put (w :rects) 4 {:left 50 :top 60 :right 350 :bottom 260})          # where the user dropped it
  ((w :move-cb) (hw 4))
  (is= 0 (length (w :pending)))                                           # no spawn, no dispatch inside the callback
  (is (not (st/floating? (state-of a) 4)))
  (pump-tick! a)
  (is (st/floating? (state-of a) 4))                                      # moved elsewhere: it floats
  (is (not (st/floating? (state-of a) 5))))

(deftest "D9: a click on the title bar (the window is where we put it) floats nothing"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (def p ((st/placements (state-of a)) 4))
  (put (w :rects) 4 {:left (p :x) :top (p :y) :right (+ (p :x) (p :w)) :bottom (+ (p :y) (p :h))})
  ((w :move-cb) (hw 4))
  (pump-tick! a)
  (is (not (st/floating? (state-of a) 4))))

(deftest "D9: events for windows Jwno does not manage are ignored, and a throwing callback is survivable"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  ((w :move-cb) (hw 99))
  (put (w :roots) 7 :dead)
  ((w :move-cb) (hw 7))                                                   # GetAncestor gave NULL
  ((w :move-cb) nil)
  (pump-tick! a)
  (is= 1 (length (st/placements (state-of a))))
  (is (not (st/floating? (state-of a) 4))))

(deftest "D9: polling compares every managed window; maximised tiles float, the rest are put back"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (managed-window w a 5)
  (managed-window w a 6)
  (def p ((st/placements (state-of a)) 4))
  (put (w :rects) 4 {:left 0 :top 0 :right 9 :bottom 9})                  # an app moved itself
  (put (w :zoomed) 5 true)
  (put (w :rects) 5 {:left 0 :top 0 :right 1000 :bottom 600})             # the user maximised it
  (array/clear (w :calls))
  ((a :poll-once))
  (is (st/floating? (state-of a) 5))                                      # maximised -> floating, stays maximised
  (is (not (st/floating? (state-of a) 4)))
  (is (find |(and (= (first $) :transform) (= (get $ 1) 4)) (w :calls)))  # 4 was put back
  (is (not (find |(and (= (first $) :transform) (= (get $ 1) 5)) (w :calls)))))

(deftest "D9: polling does not compare while a mouse button is down, nor minimised windows"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :rects) 4 {:left 0 :top 0 :right 9 :bottom 9})
  (put w :mouse true)
  (array/clear (w :calls))
  ((a :poll-once))
  (is= 0 (length (calls-of w :transform)))                                # the user may be dragging
  (put w :mouse false)
  (put (w :minimized) 4 true)
  ((a :poll-once))
  (is= 0 (length (calls-of w :transform)))                                # minimised: Jwno skips it anyway
  (put (w :minimized) 4 false)
  ((a :poll-once))
  (is (find |(= (first $) :transform) (w :calls))))

(deftest "D9: a drop that lands just before the poll is processed first, so the drop position is not lost (N2)"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (managed-window w a 5)
  (put (w :rects) 4 {:left 50 :top 60 :right 350 :bottom 260})
  (array/push (w :move-events) (hw 4))                                    # MOVESIZEEND is waiting in the queue ...
  (array/clear (w :calls))
  ((a :poll-once))                                                         # ... when the poll runs
  (is (st/floating? (state-of a) 4))
  (is (not (find |(and (= (first $) :transform) (= (get $ 1) 4)) (w :calls)))))   # never dragged back

(deftest "D9: ten failed pumps unhook and fall back to polling only"
  (def w (fake-world))
  (def a (install-adapter w))
  (put w :pump-throws true)
  (for _ 0 10 (pump-tick! a))
  (is (find |(= (first $) :unwatch-moves) (w :calls)))
  (is (find |(string/find "falling back" (string ($ 1))) (w :logs)))
  (pump-tick! a)                                                          # still harmless
  (is= 1 (length (calls-of w :unwatch-moves))))

(deftest "D9: :watch-moves? false installs no hook; shutting-down removes it; install is idempotent"
  (def w (fake-world))
  (install-adapter w {:watch-moves? false})
  (is= 0 (length (calls-of w :watch-moves)))
  (def w2 (fake-world))
  (def a2 (install-adapter w2))
  (is= 1 (length (calls-of w2 :watch-moves)))
  (is (= a2 (install-adapter w2)))                               # the second install returns the first
  (is= 1 (length (calls-of w2 :watch-moves)))
  ((get (w2 :hooks) :shutting-down))
  (is= 1 (length (calls-of w2 :unwatch-moves)))
  ((get (w2 :hooks) :shutting-down))
  (is= 1 (length (calls-of w2 :unwatch-moves))))

(deftest "D9: the pump is scheduled every 100ms by start"
  (def w (fake-world))
  (def a (install-adapter w))
  ((a :start))
  (is (find |(= 0.1 (first $)) (w :later))))

# ---- ADR 0006: workspaces by parking ------------------------------------------------------

(defn last-transform [w id]
  (last (filter |(and (= (first $) :transform) (= (get $ 1) id)) (w :calls))))

(defn rect-of [w id] (get (w :rects) id))

(deftest "ADR 0006: hide parks a window off-screen at its own size and remembers where it was; show brings it back"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :rects) 4 {:left 100 :top 50 :right 400 :bottom 350})            # the window is at 100,50 300x300
  ((get (a :ctx) :hide) 4)
  (def r (rect-of w 4))
  (is= -32000 (r :left))
  (is= -32000 (r :top))
  (is= 300 (- (r :right) (r :left)))                                       # same size
  (is= {:rect {:x 100 :y 50 :w 300 :h 300} :at {:x -32000 :y -32000 :w 300 :h 300} :hwnd {:ptr 4}} (get (a :parked) 4))
  ((get (a :ctx) :show) 4)
  (is= {:left 100 :top 50 :right 400 :bottom 350} (rect-of w 4))
  (is (nil? (get (a :parked) 4)))
  ((get (a :ctx) :show) 4)                                                 # showing a window that is not parked is harmless
  (is= {:left 100 :top 50 :right 400 :bottom 350} (rect-of w 4)))

(deftest "ADR 0006: hiding twice keeps the ORIGINAL position (a :refresh re-asserts hides)"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :rects) 4 {:left 100 :top 50 :right 400 :bottom 350})
  ((get (a :ctx) :hide) 4)
  ((get (a :ctx) :hide) 4)
  ((get (a :ctx) :show) 4)
  (is= {:left 100 :top 50 :right 400 :bottom 350} (rect-of w 4)))

(deftest "ADR 0006: placing or focusing a parked window brings it back first"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :rects) 4 {:left 100 :top 50 :right 400 :bottom 350})
  ((get (a :ctx) :hide) 4)
  ((get (a :ctx) :place) 4 {:x 10 :y 20 :w 200 :h 100})
  (is (nil? (get (a :parked) 4)))
  (is= {:left 10 :top 20 :right 210 :bottom 120} (rect-of w 4))
  ((get (a :ctx) :hide) 4)
  ((get (a :ctx) :focus) 4)
  (is (nil? (get (a :parked) 4)))
  (is (> ((rect-of w 4) :left) -30000)))

(deftest "ADR 0006: a minimised window is not parked (Jwno would skip it, and it is not on screen anyway)"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :minimized) 4 true)
  (array/clear (w :calls))
  ((get (a :ctx) :hide) 4)
  (is= 0 (length (calls-of w :transform)))
  (is (nil? (get (a :parked) 4))))

(deftest "ADR 0006: the poll parks a window again if an app moved itself back on-screen, without telling the core"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :rects) 4 {:left 100 :top 50 :right 400 :bottom 350})
  ((get (a :ctx) :hide) 4)
  (put (w :rects) 4 {:left 640 :top 480 :right 940 :bottom 780})           # the app restored its saved position
  (array/clear (w :calls))
  ((a :poll-once))
  (is (< ((rect-of w 4) :left) -30000))                                    # parked again
  (is (not (find |(and (= (first $) :transform) (not= (get $ 1) 4)) (w :calls)))))

(deftest "ADR 0006 H1: shutting down brings every parked window back; nothing is left off-screen"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (managed-window w a 5)
  (put (w :rects) 4 {:left 100 :top 50 :right 400 :bottom 350})
  (put (w :rects) 5 {:left 500 :top 60 :right 800 :bottom 360})
  ((get (a :ctx) :hide) 4)
  ((get (a :ctx) :hide) 5)
  ((get (w :hooks) :shutting-down))
  (is= {:left 100 :top 50 :right 400 :bottom 350} (rect-of w 4))
  (is= {:left 500 :top 60 :right 800 :bottom 360} (rect-of w 5))
  (is= 0 (length (keys (a :parked)))))

(deftest "ADR 0006 H1: start recovers windows a previous run left off-screen"
  (def w (fake-world))
  (def stray ((w :add-window!) 4 g1))
  (put (w :rects) 4 {:left -32000 :top -32000 :right -31700 :bottom -31700})   # left behind by a crash
  (def fine ((w :add-window!) 5 g1))
  (put (w :rects) 5 {:left 100 :top 50 :right 400 :bottom 350})
  (def a (install-adapter w))
  ((a :start))
  (is (> ((rect-of w 4) :left) -30000))
  (is= 0 ((rect-of w 4) :left))                                            # at the work area's origin
  (is (> ((rect-of w 5) :left) -30000))                                    # the core tiles it as usual
  # only the stray was recovered, not the window that was fine
  (is= 1 (length (filter |(string/find "recovering window" (string ($ 1))) (w :logs)))))

(deftest "ADR 0006: goto parks the old workspace and brings the other one back, end to end"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (managed-window w a 5)
  ((a :norm) (hw 6))                                        # let the adapter know window 6 (it lives on workspace 2)
  ((w :add-window!) 6 g1)
  ((a :enumerate))
  (rt/dispatch (a :rt) [:window-opened 6 "2"])              # opened while we look at workspace 1: hidden at once
  (is (< ((rect-of w 6) :left) -30000))
  (def p4 (rect-of w 4))
  (rt/dispatch (a :rt) [:command :goto "2"])
  (is (< ((rect-of w 4) :left) -30000))                     # workspace 1 is parked ...
  (is (< ((rect-of w 5) :left) -30000))
  (is (> ((rect-of w 6) :left) -30000))                     # ... and 2 is on screen
  (rt/dispatch (a :rt) [:command :goto "1"])
  (is (> ((rect-of w 4) :left) -30000))
  (is (> ((rect-of w 5) :left) -30000))
  (is (< ((rect-of w 6) :left) -30000))
  (is (not (nil? p4))))

(deftest "ADR 0006: a floating window comes back to where it was after its workspace was away"
  (def w (fake-world))
  (def a (install-adapter w {:rules [{:match {:class "#32770"} :action :float}]}))
  (def dlg ((w :add-window!) 4 g1))
  (def uia @{:get_CachedClassName (fn [self] "#32770") :get_CachedName (fn [self] "Save As")})
  ((get (w :hooks) :window-created) dlg uia "x" {:id g1})
  (flush! w)
  (is (st/floating? (state-of a) 4))
  (put (w :rects) 4 {:left 300 :top 200 :right 700 :bottom 500})            # where the user keeps it
  (rt/dispatch (a :rt) [:window-opened 9 "2"])
  (rt/dispatch (a :rt) [:command :goto "2"])                                 # nothing to focus there: still switches
  (rt/dispatch (a :rt) [:command :goto "1"])
  (is= {:left 300 :top 200 :right 700 :bottom 500} (rect-of w 4)))

(deftest "ADR 0006: a drag event for a parked window is ignored (it is off-screen; nobody dragged it)"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (managed-window w a 5)
  ((get (a :ctx) :hide) 4)
  ((w :move-cb) (hw 4))
  (pump-tick! a)
  (is (not (st/floating? (state-of a) 4))))

(deftest "the :xtile command takes a bare number as a workspace tag (easier to type in jwno.exe -x)"
  (def w (fake-world))
  (def a (install-adapter w {:keymap (w :keymap) :bindings []}))
  (managed-window w a 4)
  (managed-window w a 5)
  ((w :xtile-command) :goto 2)
  (is= "2" ((state-of a) :current))
  ((w :xtile-command) :goto "1")
  (is= "1" ((state-of a) :current))
  ((w :xtile-command) :focus-next)                 # other commands are untouched
  (is= "1" ((state-of a) :current)))

(deftest "after stop nothing re-arms itself: Jwno must be able to exit (a self-rescheduling timer keeps the event loop alive)"
  (def w (fake-world))
  (def a (install-adapter w))
  ((a :start))
  (is (> (length (w :later)) 0))
  ((get (w :hooks) :shutting-down))
  (is ((a :stopped?)))
  # whatever timers are still pending fire once more, and must not schedule anything new
  (def pending (array ;(w :later)))
  (array/clear (w :later))
  (each [_ f] pending (f))
  (is= 0 (length (w :later))))

(deftest "filter-window: Jwno must not even manage a window of another Windows virtual desktop (its transform would un-maximise it)"
  (def w (fake-world))
  (put w :desktop g1)
  (def a (install-adapter w))
  (def here ((w :add-window!) 4 g1))
  (def there ((w :add-window!) 5 g2))
  (def filter (get (w :hooks) :filter-window))
  (is filter)
  (is (filter (hw 4) :uia "x" {:id g1}))                 # this desktop: Jwno may manage it
  (is (not (filter (hw 5) :uia "x" {:id g2})))           # another desktop: hands off
  # no desktop was ever created: everything is ours
  (def w2 (fake-world))
  (install-adapter w2)
  ((w2 :add-window!) 6 g2)
  (is ((get (w2 :hooks) :filter-window) (hw 6) :uia "x" {:id g2}))
  # the filter must never block Jwno when the question cannot be answered
  (def w3 (fake-world))
  (put w3 :win32 (merge (w3 :win32) {:on-current-desktop? (fn [_] (error "COM failed"))}))
  (install-adapter w3)
  (is ((get (w3 :hooks) :filter-window) (hw 7) :uia "x" nil)))

(deftest "start offers top-level windows Jwno does not manage to Jwno (real run 3: only the focused one was managed)"
  (def w (fake-world))
  ((w :add-window!) 5)                 # managed already
  (array/push (w :top) 5 6 7)          # UIA also lists 6 and 7
  (def a (install-adapter w))
  ((a :start))
  (def opened (map |($ 1) (calls-of w :window-opened)))
  (assert (deep= opened @[6 7]) (string/format "opened %q logs %q" opened (w :logs))))

(deftest "Opus H1: a parked window is brought back even when its desktop is not the current one any more"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :rects) 4 {:left 100 :top 50 :right 400 :bottom 350})
  ((get (a :ctx) :hide) 4)
  # the user switches to another virtual desktop: enumerate no longer knows window 4
  (put (w :guids) 4 "{A}")
  (put w :desktop "{B}")
  ((a :poll-once))
  ((a :stop))                                                       # Jwno quits while on the other desktop
  (is= {:left 100 :top 50 :right 400 :bottom 350} (rect-of w 4))
  (is (nil? (get (a :parked) 4))))

(deftest "Opus H1: the parked entry of a destroyed window is dropped, not kept for ever"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :rects) 4 {:left 100 :top 50 :right 400 :bottom 350})
  ((get (a :ctx) :hide) 4)
  (put (w :roots) 4 :dead)                                          # the window was destroyed
  (put w :desktop "{B}") (put (w :guids) 4 "{A}")
  ((a :poll-once))
  ((a :stop))
  (is (nil? (get (a :parked) 4))))

(deftest "D-6: :show brings back a window that is off-screen but not in `parked` (the entry was lost)"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :rects) 4 {:left -32000 :top -32000 :right -31700 :bottom -31700})
  ((get (a :ctx) :show) 4)
  (is (> ((rect-of w 4) :left) -30000))
  # an on-screen window is left alone
  (put (w :rects) 4 {:left 100 :top 50 :right 400 :bottom 350})
  ((get (a :ctx) :show) 4)
  (is= {:left 100 :top 50 :right 400 :bottom 350} (rect-of w 4)))

(deftest "D-6: Jwno purging a live window (an app hiding in the tray) keeps its parked entry"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (put (w :rects) 4 {:left 100 :top 50 :right 400 :bottom 350})
  ((get (a :ctx) :hide) 4)
  ((get (w :hooks) :window-removed) ((w :windows) 4))
  (is (get (a :parked) 4))                                          # the window still exists
  (put (w :roots) 4 :dead)
  ((get (w :hooks) :window-removed) ((w :windows) 4))
  (is (nil? (get (a :parked) 4))))

(deftest "D-7f: a reclaim focus never takes the focus from a window the user can see; a plain focus does"
  (def w (fake-world))
  (def a (install-adapter w))
  (managed-window w a 4)
  (managed-window w a 5)
  (put (w :rects) 4 {:left 0 :top 0 :right 100 :bottom 100})            # on screen
  (put (w :rects) 5 {:left 200 :top 0 :right 300 :bottom 100})
  (put w :fg (hw 4))
  (array/clear (w :calls))
  ((get (a :ctx) :focus) 5 :reclaim)
  (is= 0 (length (calls-of w :window-set-focus)))
  ((get (a :ctx) :focus) 5)
  (is= 1 (length (calls-of w :window-set-focus)))
  # the front window is a parked one: the reclaim goes ahead
  (put (w :rects) 4 {:left -32000 :top -32000 :right -31900 :bottom -31900})
  (put w :fg (hw 4))
  ((get (a :ctx) :focus) 5 :reclaim)
  (is= 2 (length (calls-of w :window-set-focus))))

(deftest "D-7b: focus-none without a sink window warns and succeeds (it must not cause a recovery)"
  (def w (fake-world))
  (def a (install-adapter w))
  (is= true ((get (a :ctx) :focus-none)))
  (is (find |(string/find "no sink window" ($ 1)) (w :logs))))
