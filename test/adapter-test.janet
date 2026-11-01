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
           :minimized @{} :hung @{}
           :rects @{}            # ptr -> actual visible rect after a transform (default: as asked)
           :desktops @[]         # [index guid name]
           :refreshes 0
           :last-vd nil
           :hooks @{}})
  (defn rec [& c] (array/push (w :calls) c))

  (def win-proto
    @{:transform (fn [self rect tags wm]
                   (rec :transform ((self :hwnd) :ptr) rect (merge (self :tags) tags))
                   (put (w :rects) ((self :hwnd) :ptr)
                        (or (get (w :rects) ((self :hwnd) :ptr))
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
    @{:get-window-stack (fn [self] (map |((w :windows) $) (w :order)))
      :get-all-windows (fn [self] (values (w :windows)))})
  (def wm-proto
    @{:find-hwnd (fn [self hwnd] ((w :windows) (hwnd :ptr)))
      :enumerate-monitors (fn [self] [[{:work-area {:left 0 :top 0 :right 1000 :bottom 600}}] 0])
      :set-focus (fn [self node] (rec :wm-set-focus node))
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
  (def cmd-man @{:add-command (fn [self name f] (put w :xtile-command f))})
  (put w :wm wm)
  (put w :context {:window-manager wm :hook-manager hook-man :virtual-desktop-manager vd-man
                   :command-manager cmd-man})
  (put w :keymap keymap)
  (put w :win32
       {:foreground-hwnd (fn [] (w :fg))
        :root-of (fn [h] (def p (h :ptr))
                   (def r (get (w :roots) p p))
                   (if (= r :dead) nil (hw r)))
        :hwnd->number (fn [h] (h :ptr))
        :facts (fn [h] {:class "K" :visible? true :exe (string "a" (h :ptr) ".exe")})
        :desktop-guid (fn [h] (get (w :guids) (h :ptr)))
        :minimized? (fn [h] (truthy? (get (w :minimized) (h :ptr))))
        :hung? (fn [h] (truthy? (get (w :hung) (h :ptr))))
        :beep (fn [] (rec :beep))
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

(deftest "a window on a desktop we cannot map is never given to the core (and the cache is re-read once)"
  (def w (fake-world))
  (put w :desktops @[[1 g1 nil]])
  (def a (install-adapter w))
  (def win ((w :add-window!) 7 g2))
  ((get (w :hooks) :window-created) win :uia "x" {:id g2 :name :default})
  (is= 0 (length (w :pending)))                   # not even an event: the core is never told
  (flush! w)
  (is (nil? (st/locate (state-of a) 7)))
  (is= 1 (w :refreshes))
  # desktop 10 and beyond: no tag exists
  (def w2 (fake-world))
  (put w2 :desktops (array/concat @[] (seq [i :range [1 11]] [i (string "{G" i "}") nil])))
  (def a2 (install-adapter w2))
  (is= "9" ((a2 :tag-of-guid) "{G9}"))
  (is= :unmappable ((a2 :tag-of-guid) "{G10}"))
  (is (nil? ((a2 :tag-of-guid) nil))))

(deftest "no desktops created yet: everything is workspace 1"
  (def w (fake-world))
  (def a (install-adapter w))
  (is= "1" ((a :tag-of-guid) "{ANY}")))

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
  (is (not (first (protect ((get (a :ctx) :goto) "2"))))))

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

(deftest "virtual-desktop-changed: tag, or the reserved empty workspace when we cannot map it"
  (def w (fake-world))
  (put w :desktops @[[1 g1 nil] [2 g2 nil]])
  (def a (install-adapter w))
  ((get (w :hooks) :virtual-desktop-changed) g2 "Desktop 2" nil)
  (flush! w)
  (is= "2" ((state-of a) :current))
  ((get (w :hooks) :virtual-desktop-changed) "{UNKNOWN}" "?" nil)
  (flush! w)
  (is= "0" ((state-of a) :current)))

(deftest "start: the core's current workspace follows the OS before windows are observed (N1)"
  (def w (fake-world))
  (put w :desktops @[[1 g1 nil] [2 g2 nil]])
  ((w :add-window!) 4 g2)
  (put (w :wm) :last-vd g2)
  (def a (install-adapter w))
  ((a :start))
  (is= "2" ((state-of a) :current))
  (is= "2" (st/locate (state-of a) 4))
  (is (find |(= 2 (first $)) (w :later))))        # polling is scheduled (besides the re-observation)

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
  (is= "1" ((first snap) 1))
  # a window on a desktop we cannot map is left out of the snapshot (it would be a ghost to the core)
  (put w :desktops @[[1 g1 nil]])
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
