# Random event sequences; invariants must hold after every step.
# The invariant list is docs/INVARIANTS.md -- keep the two in sync.
(use ./t)
(import ../src/core/geometry :as g)
(import ../src/core/state :as st)
(import ../src/core/update :as u)
(import ../src/core/workspace :as ws)
(import ../src/core/classify :as cl)
(import ../src/core/layout)

(def tags ["1" "2" "3"])
(def screens
  [(g/rect 0 0 1920 1080) (g/rect -1920 0 1920 1080) (g/rect 100 50 1280 720)
   (g/rect 0 -1080 2560 1440)])

(def commands
  [[:command :focus-next] [:command :focus-prev] [:command :focus-master]
   [:command :swap-next] [:command :swap-prev] [:command :swap-master]
   [:command :shift-master]
   [:command :inc-master] [:command :dec-master]
   [:command :expand] [:command :shrink] [:command :next-layout]
   [:command :close] [:command :refresh] [:command :toggle-float] [:command :reclaim-focus]
   [:command :reassert-focus] [:command :reassert-focus 1 2] [:command :reassert-focus :w1]
   [:command :set-layout :tall] [:command :set-layout :wide]
   [:command :set-layout :full] [:command :set-layout :bogus]
   [:command :bogus]])

(def malformed
  [[] [:window-opened] [:window-closed] [:focus-changed] [:command]
   [:screen-changed] [:window-moved] [:nope 1 2 3] [:command :goto]
   [:command :send] [:window-opened nil] [:desktop-changed nil]
   # ill-typed, mutable, or degenerate values
   [:screen-changed 5] [:screen-changed {:x 0}]
   [:screen-changed {:x 0 :y 0 :w -5 :h 10}] [:screen-changed {:x 0 :y 0 :w 0 :h 10}]
   [:screen-changed {:x 0.5 :y 0 :w 10 :h 10}]
   [:window-opened @[1]] [:window-opened :z @"1"] [:window-opened @{:a 1}]
   [:window-closed @[1]] [:focus-changed @[1]] [:desktop-changed @"1"]
   [:window-moved :w1 5] [:window-moved @[1] {:x 0 :y 0 :w 1 :h 1}]
   [:windows-observed 5] [:windows-observed [5 [:a]]] [:windows-observed [[@[1] "1"]]]
   [:window-seen :w1 5] [:window-seen :w1] [:window-seen :w1 nil] [:window-seen @[1] {}]
   [:window-dragged] [:window-dragged :w1] [:window-dragged :w1 5] [:window-dragged @[1] {:x 0 :y 0 :w 5 :h 5}]
   [:window-dragged :w1 {:x 0 :y 0 :w 0 :h 5}]
   [:window-seen :w1 "x" "1"] [:windows-observed [[:w1 "1" 5] [:w2 nil nil]]]
   [:command :goto @"1"] [:command @[1]] [:command :set-layout @[1]]])

(defn pick [rng xs] (xs (math/rng-int rng (length xs))))

(def rule-pool
  [{:match {:exe "a.exe"} :action :float}
   {:match {:exe "b.exe"} :action :ignore}
   {:match {:class "#32770"} :action :tile}
   {:match {:exe "c.exe"} :action :tile}])

(defn random-rules [rng]
  (tuple ;(seq [_ :range [0 (math/rng-int rng 4)]] (pick rng rule-pool))))

(def screen-pairs
  [[(g/rect 0 0 1000 600) (g/rect 1000 0 1000 600)]
   [(g/rect 0 0 1920 1080) (g/rect -1280 0 1280 720)]])

(defn new-state
  "One screen (the old behaviour) most of the time, two screens (ADR 0012) one time in three; one state in four
  with :follow (ADR 0006 D-7e), which the frozen v0 core knows too."
  [rng]
  (def mode (if (zero? (math/rng-int rng 4)) :follow nil))
  (if (zero? (math/rng-int rng 3))
    (st/make (pick rng screen-pairs) tags (random-rules rng) mode)
    (st/make (first screens) tags (random-rules rng) mode)))

(defn random-facts
  "Mostly valid facts; sometimes not even a dictionary."
  [rng]
  (if (zero? (math/rng-int rng 8))
    (pick rng [nil 5 "x" [1]])
    (merge {:class "K" :visible? true
            :exe (pick rng ["C:\\x\\a.exe" "C:\\x\\b.exe" "C:\\x\\c.exe"])}
           (pick rng [{} {} {} {:dialog? true} {:owned? true} {:class "#32770"}
                      {:minimized? true} {:fullscreen? true} {:visible? false}
                      {:tool-window? true}]))))

(defn random-event [rng]
  (def id (keyword "w" (math/rng-int rng 12)))
  (case (math/rng-int rng 24)
    0 [:window-opened id]
    1 [:window-opened id (pick rng tags)]
    2 [:window-opened id "bogus"]
    3 [:window-closed id]
    4 [:focus-changed id]
    5 [:focus-changed nil]
    6 [:desktop-changed (pick rng [;tags "bogus"])]
    7 [:screen-changed (pick rng screens)]
    8 [:window-moved id (g/rect (math/rng-int rng 50) 0 100 100)]
    9 (if (zero? (math/rng-int rng 3))
        [:command :view (pick rng [;tags "bogus"])]
        [:command :goto (pick rng [;tags "bogus"])])
    10 [:command :send (pick rng [;tags "bogus"])]
    11 (pick rng malformed)
    12 [:windows-observed
        (tuple ;(seq [_ :range [0 (math/rng-int rng 6)]]
                  [(keyword "w" (math/rng-int rng 12))
                   (pick rng [nil ;tags])]))]
    13 [:window-opened (math/rng-int rng 5)]
    14 [:window-seen id (random-facts rng)]
    15 [:window-seen id (random-facts rng) (pick rng tags)]
    16 [:command :toggle-float]
    18 [:window-dragged id (pick rng [(first screens) (g/rect 3 4 50 60) (g/rect (math/rng-int rng 40) 0 100 100)])]
    19 [:window-dragged id (g/rect 0 0 (+ 1 (math/rng-int rng 500)) 300)]
    20 [:window-surfaced id]
    17 [:windows-observed
        (tuple ;(seq [_ :range [0 (math/rng-int rng 6)]]
                  [(keyword "w" (math/rng-int rng 12))
                   (pick rng [nil ;tags])
                   (random-facts rng)]))]
    (pick rng commands)))

(def silent-kinds
  {:focus-changed true :desktop-changed true :windows-observed true :window-surfaced true})
(def idempotent-kinds
  {:window-opened true :window-seen true :window-dragged true :window-closed true :focus-changed true :window-surfaced true
   :desktop-changed true :screen-changed true :windows-observed true})

# kinds that are not OS focus observations: they must never clear
# :external-focus (E10)
(def non-focus-observation
  {:window-closed true :screen-changed true :window-surfaced true
   :window-moved true :window-dragged true :command true})
# window-opened may clear external focus only for the id last observed as OS
# focus (Jwno reports focus before :window-opened) -- checked in check-external

(defn immutable? [x]
  (case (type x)
    :table false :array false :buffer false :fiber false :function false
    :tuple (all immutable? x)
    :struct (all |(and (immutable? (0 $)) (immutable? (1 $))) (pairs x))
    true))

(defn check-invariants [s event]
  (unless (immutable? s)
    (errorf "I0 state contains mutable data after %q" event))
  (def screen (st/screen s))
  (def all (mapcat |(((s :workspaces) $) :ids) (s :tags)))
  (each id (keys (s :floating))
    (unless (index-of id all)
      (errorf "F1 floating id %q is not in the stack after %q" id event)))
  (each id (keys (get s :misfit {}))
    (unless (index-of id all)
      (errorf "F1 misfit id %q is not in the stack after %q" id event)))
  (unless (= (length all) (length (distinct all)))
    (errorf "I1 duplicate window after %q: %q" event all))
  (each tag (s :tags)
    (def w ((s :workspaces) tag))
    (unless (or (nil? (w :focus)) (ws/has? w (w :focus)))
      (errorf "I2 dangling focus after %q" event))
    (when (and (empty? (w :ids)) (w :focus))
      (errorf "I2 focus on empty workspace after %q" event))
    (when (and (not (empty? (w :ids))) (nil? (w :focus)))
      (errorf "I2 no focus on non-empty workspace after %q" event))
    (unless (and (>= (w :nmaster) 0) (<= 0.1 (w :ratio) 0.9))
      (errorf "I3 layout params out of range after %q" event)))
  (unless (index-of (st/current s) (s :tags))
    (errorf "I4 bad current after %q" event))
  # Q4: a pending :goto focus always names a window in the stack, on the visible workspace's tag
  (when-let [p (s :pending-focus)]
    (unless (index-of (p :target) all)
      (errorf "Q4 pending target %q is not in the stack after %q" (p :target) event))
    (unless (= (p :tag) (st/current s))
      (errorf "Q4 pending tag %q is not current after %q" (p :tag) event)))
  (def p (st/placements s))
  (def tiled (mapcat |(st/tiled-ids s (st/ws-of s $)) (st/visible-tags s)))
  (unless (= (length p) (length tiled))
    (errorf "I5 placement count mismatch after %q" event))
  # per screen (ADR 0012): F7 the layout sees the stack minus the floats, I6 inside the screen, I7 tiling covers it
  (each scr (s :screens)
    (def w (st/ws-of s (scr :ws)))
    (def rect (scr :rect))
    (def stripped (reduce |(ws/remove $0 $1) w (filter |(st/floating? s $) (w :ids))))
    (def mine (table/to-struct (from-pairs (layout/arrange (w :layout) w rect (stripped :ids)))))
    (each id (st/tiled-ids s w)
      (unless (= (mine id) (p id))
        (errorf "F7 placement of %q differs from the float-free workspace after %q" id event)))
    (def rs (map |(p $) (st/tiled-ids s w)))
    (each r rs
      (unless (and (>= (r :x) (rect :x)) (>= (r :y) (rect :y))
                   (<= (+ (r :x) (r :w)) (+ (rect :x) (rect :w)))
                   (<= (+ (r :y) (r :h)) (+ (rect :y) (rect :h)))
                   (pos? (r :w)) (pos? (r :h)))
        (errorf "I6 rect out of bounds after %q: %q in %q" event r rect)))
    (unless (= (w :layout) :full)
      (unless (empty? rs)
        (unless (= (sum (map g/area rs)) (g/area rect))
          (errorf "I7 tiling does not cover screen after %q" event)))
      (for i 0 (length rs)
        (for j (+ i 1) (length rs)
          (when (g/overlap? (rs i) (rs j))
            (errorf "I7 overlap after %q" event))))))
  # M-2: every workspace is on at most one screen
  (unless (= (length (distinct (st/visible-tags s))) (length (st/visible-tags s)))
    (errorf "M-2 a workspace is shown on two screens after %q" event))
  (unless (< -1 (s :focused-screen) (length (s :screens)))
    (errorf "M-1 the focused screen is out of range after %q" event)))

(defn- stack-ids [s] (mapcat |(((s :workspaces) $) :ids) (s :tags)))

(defn check-window-seen [old r event]
  (def s (r :state))
  (def kind (get event 0))
  (when (= kind :window-seen)
    (def [_ id facts] event)
    (def known (and (or (number? id) (keyword? id) (string? id)) (index-of id (stack-ids old))))
    (cond
      # F11: facts that are not a dictionary change nothing
      (not (dictionary? facts))
      (unless (and (deep= s old) (empty? (r :effects)))
        (errorf "F11 invalid facts changed something: %q" event))
      # F4: a known window that is not hidden is left alone
      (and known (not (cl/hidden? facts)))
      (unless (and (deep= s old) (empty? (r :effects)))
        (errorf "F4 window-seen on a visible known window changed something: %q" event))
      # F5 / F8: hidden removes it everywhere; if the OS focus was on it we
      # keep the observation, mark focus external and do not echo a :focus
      (and known (cl/hidden? facts))
      (do
        (when (or (index-of id (stack-ids s)) (st/floating? s id) (get-in s [:misfit id]))
          (errorf "F5 hidden window left traces: %q" event))
        (when (= id (old :os-focus))
          (unless (and (s :external-focus) (= id (s :os-focus)))
            (errorf "F8 hidden OS-focused window did not make focus external: %q" event))
          (when (find |(= (first $) :focus) (r :effects))
            (errorf "F8 :focus emitted for a hidden OS-focused window: %q" event)))))))

(defn check-reassert [old r event]
  (def s (r :state))
  (def name (get event 1))
  (when (= (get event 0) :command)
    # Q3: any command other than :reassert-focus / :reclaim-focus / :goto leaves nothing pending
    (when (and (not (index-of name [:reassert-focus :reclaim-focus :goto :view])) (s :pending-focus))
      (errorf "Q3 pending survived a new command after %q" event))
    (when (and (index-of name [:goto :view]) (s :pending-focus))
      (unless (= ((s :pending-focus) :target) (st/focused s))
        (errorf "Q3 goto left a pending focus on a different window: %q" event)))
    (when (= name :reassert-focus)
      (def p (old :pending-focus))
      (def t (and p (p :target)))
      (def os (old :os-focus))
      (def want?
        (and (= 2 (length event)) t os
             (= (st/locate old t) (st/current old))
             (not (old :external-focus))
             (not (st/floating? old os))
             (not= os t)))
      (if want?
        (do
          # Q1/Q2: exactly one :focus on the target, consumed, nothing else moves
          (unless (deep= (tuple ;(r :effects)) [[:focus t]])
            (errorf "Q1 reassert should emit only [:focus %q], got %q" t (r :effects)))
          (unless (nil? (s :pending-focus))
            (errorf "Q2 reassert did not consume the pending focus"))
          (each k [:external-focus :os-focus :floating]
            (unless (deep= (old k) (s k))
              (errorf "Q2 reassert changed %q" k)))
          (unless (= (st/current old) (st/current s)) (errorf "Q2 reassert changed the current workspace"))
          (unless (= (st/focused s) t)
            (errorf "Q2 reassert did not move the model focus to the target")))
        (unless (and (deep= s old) (empty? (r :effects)))
          (errorf "Q1/Q6 reassert acted when it must not: %q -> %q" event (r :effects)))))))

(defn- int-ish? [x] (and (number? x) (= x (math/floor x))))

(defn check-dragged [old r event]
  (when (= (get event 0) :window-dragged)
    (def s (r :state))
    (def [_ id rect] event)
    (def valid? (and (or (number? id) (keyword? id) (string? id))
                     (struct? rect) (int-ish? (get rect :x)) (int-ish? (get rect :y))
                     (int-ish? (get rect :w)) (int-ish? (get rect :h)) (pos? (get rect :w)) (pos? (get rect :h))))
    (def tag (and valid? (st/locate old id)))
    (def acts? (and tag (st/visible-tag? old tag) (not (st/floating? old id))))     # any screen (ADR 0012)
    (cond
      (not acts?)
      (unless (and (deep= s old) (empty? (r :effects)))
        (errorf "D: window-dragged changed something it must ignore: %q" event))
      (= rect ((st/placements old) id))
      # a click on the title bar: not floating (D2); at most a stale misfit is dropped
      (do
        (when (st/floating? s id) (errorf "D2 an unmoved window became floating: %q" event))
        (unless (deep= (r :effects) []) (errorf "D2 unmoved window produced effects: %q" event)))
      (do
        (unless (st/floating? s id) (errorf "D1 a moved window did not become floating: %q" event))
        (each k [:os-focus :external-focus]
          (unless (deep= (old k) (s k)) (errorf "D1 window-dragged changed %q" k)))
        (unless (= (st/current old) (st/current s)) (errorf "D1 window-dragged changed the current workspace"))
        (unless (deep= ((st/ws-of old tag) :ids) ((st/ws-of s tag) :ids))
          (errorf "D1 window-dragged reordered the stack: %q" event))
        (unless (= (st/focused old) (st/focused s)) (errorf "D1 window-dragged moved the focus: %q" event))
        (when (find |(and (= (first $) :place) (= (get $ 1) id)) (r :effects))
          (errorf "D4 the dragged window was placed again: %q" event))))))

(defn- vis-of [s] (st/vis-ids s))

(defn check-visibility [old r event]
  (def s (r :state))
  (def new-all (stack-ids s))
  (def old-all (stack-ids old))
  (def hides (map |($ 1) (filter |(= (first $) :hide) (r :effects))))
  (def shows (map |($ 1) (filter |(= (first $) :show) (r :effects))))
  (each id hides
    # H-a: only windows the model still has, and not on the workspace we are looking at
    (unless (and (index-of id new-all) (not (index-of id (vis-of s))))
      (errorf "H-a :hide %q is not on a hidden workspace after %q" id event)))
  (each id hides
    # H-e: not again for a window that was already hidden (that is noise, and re-parks a window needlessly)
    # (:refresh is the exception: it re-asserts every hidden window on purpose, to re-park strays)
    (unless (or (index-of id (vis-of old)) (not (index-of id old-all)) (= event [:command :refresh]))
      (errorf "H-e :hide %q was already hidden before %q" id event)))
  (each id shows
    # H-b (ADR 0006 D-6): visible now, and not visible before (also a window that is new to the model)
    # (:refresh is the exception: it shows every visible window again, to recover a stray)
    (unless (and (index-of id (vis-of s))
                 (or (= event [:command :refresh]) (not (index-of id (vis-of old)))))
      (errorf "H-b :show %q was not a window that entered the visible workspace after %q" id event)))
  # ... and every window that entered the visible workspace gets one
  (each id (vis-of s)
    (unless (or (index-of id (vis-of old)) (index-of id shows))
      (errorf "H-b window %q entered the visible workspace without :show after %q" id event)))
  (unless (= (length hides) (length (distinct hides))) (errorf "H-d duplicate :hide after %q" event))
  (unless (= (length shows) (length (distinct shows))) (errorf "H-d duplicate :show after %q" event))
  (each id hides (when (index-of id shows) (errorf "H-d %q is both hidden and shown after %q" id event)))
  (each e (r :effects)
    (when (and (= (first e) :place) (or (index-of (e 1) hides) (not (index-of (e 1) (vis-of s)))))
      (errorf "H-d :place for a window that is not visible after %q" event))))

(defn check-stray [old r event]
  "ADR 0006 D-7 / F12."
  (def s (r :state))
  (def fx (r :effects))
  (def none? (find |(= (first $) :focus-none) fx))
  (def focus? (find |(= (first $) :focus) fx))
  (def marked? (find |(and (index-of (first $) [:focus :focus-none]) (= (last $) :reclaim)) fx))
  (def kind (first event))
  # F12d: never both; :focus-none only when the visible workspace is empty
  (when (and none? focus?) (errorf "F12d :focus and :focus-none together after %q" event))
  # ADR 0012 M12-L2: "empty" means the workspace of the FOCUSED screen (another screen may still have windows)
  (when (and none? (not (empty? ((st/current-ws s) :ids)))) (errorf "F12d :focus-none with a non-empty workspace after %q" event))
  # F12b: nothing is stolen when the OS focus is not on a known window of a hidden workspace
  (when (and marked? (not (u/stray? old))) (errorf "F12b a reclaim effect without a stray focus after %q" event))
  # (ADR 0012 R12i-H1: also after goto/:view when the focused screen's workspace is empty and the OS focus is on a
  # window shown on ANOTHER screen)
  (def other-screen-focus?
    (let [os (s :os-focus) tag (and os (st/locate s os))]
      (and tag (st/visible-tag? s tag) (not= tag (st/current s)))))
  (when (and none? (not (u/stray? s)) (not marked?) (not other-screen-focus?))
    (errorf "F12b :focus-none without a stray focus after %q" event))
  # F12c: silent observations never produce :focus-none directly
  (when (and none? (silent-kinds kind)) (errorf "F12c :focus-none from a silent event %q" event))
  # F12a: a state-changing, non-silent transition that leaves the focus on a parked window corrects it
  (when (and (u/stray? s) (not (silent-kinds kind)) (not= old s)
             (not (index-of kind [:window-moved :command]))
             (not (or focus? none?)))
    (errorf "F12a the OS focus stays on a parked window after %q" event))
  (when (and (= kind :command) (index-of (get event 1) [:goto :send :close :toggle-float])
             (u/stray? s) (or (not= (st/current old) (st/current s)) (not (deep= (sort (array ;(vis-of old))) (sort (array ;(vis-of s))))))
             (not (or focus? none?)))
    (errorf "F12a (command) the OS focus stays on a parked window after %q: fx=%q os=%q cur=%q tag=%q focused=%q ext=%q" event fx (s :os-focus) (st/current s) (st/locate s (s :os-focus)) (st/focused s) (s :external-focus))))

(defn- valid-id-test? [x] (or (number? x) (keyword? x) (string? x)))

(defn check-surfaced [old r event]
  "S-1 (ADR 0006 rev.5b)"
  (when (= (first event) :window-surfaced)
    (def s (r :state))
    (def id (get event 1))
    (def was (and (valid-id-test? id) (st/locate old id)))
    (cond
      (or (nil? was) (st/visible-tag? old was))     # unknown, or already shown on some screen (ADR 0012)
      (unless (= s old) (errorf "S-1 an unknown/visible window changed the state: %q" event))
      (do
        (unless (= (st/locate s id) (st/current s)) (errorf "S-1 the surfaced window is not on the current workspace: %q" event))
        (unless (st/floating? s id) (errorf "S-1 the surfaced window is not a float: %q" event))
        (unless (find |(= $ [:show id]) (r :effects)) (errorf "S-1 no :show for the surfaced window: %q" event))
        (when (find |(and (= (first $) :place) (= (get $ 1) id)) (r :effects)) (errorf "S-1 a float was placed: %q" event))
        (unless (= (st/current old) (st/current s)) (errorf "S-1 :current changed: %q" event))
        (unless (= (old :os-focus) (s :os-focus)) (errorf "S-1 :os-focus changed: %q" event))))))

(defn check-effects [old r event]
  (def s (r :state))
  (check-surfaced old r event)
  (check-visibility old r event)
  (check-stray old r event)
  (check-dragged old r event)
  (check-reassert old r event)
  # Q5 (E2 extension): a :focus always targets a window of the CURRENT workspace,
  # so the core never causes an implicit desktop switch
  (each e (r :effects)
    (when (= (first e) :focus)
      (unless (index-of (e 1) ((st/current-ws s) :ids))
        (errorf "Q5 :focus %q is not on the current workspace after %q" (e 1) event))))
  (def p (st/placements s))
  (def fx (r :effects))
  (def kind (get event 0))
  (each e fx
    (case (e 0)
      :place (do
               (when (st/floating? s (e 1))
                 (errorf "F2 :place for a floating window after %q" event))
               (unless (and (p (e 1)) (= (p (e 1)) (e 2)))
                 (errorf "E1/F2 stale or missing :place after %q" event)))
      :focus (unless (= (e 1) (st/focused s))
               (errorf "E2 wrong :focus after %q" event))))
  # E3 echo suppression: what the OS already did is never sent back as :focus
  (when (silent-kinds kind)
    (when (find |(= (first $) :focus) fx)
      (errorf "E3 silent event echoed a :focus: %q" event)))
  # E4 focus completeness: a non-silent event that moved the visible
  # workspace's focus must say so
  (when (and (not (silent-kinds kind)) (st/focused s)
             (not (s :external-focus))
             (not= (st/focused s) (st/focused old))
             (= (st/current s) (st/current old))
             (not= kind :window-moved))
    (unless (find |(= $ [:focus (st/focused s)]) fx)
      (errorf "E4 focus changed without :focus effect after %q" event)))
  (check-window-seen old r event)
  # E12 (was E5): destructive commands act only on the window the OS last
  # reported as focused, no matter what the model believes
  (def os-focus (old :os-focus))
  (each e fx
    (when (index-of (first e) [:close :send])
      (unless (and os-focus (= (e 1) os-focus))
        (errorf "E12 %q targets %q but the OS focus was %q (after %q)"
                (first e) (e 1) os-focus event))))
  (when (and (= kind :command)
             (index-of (get event 1) [:swap-next :swap-prev :swap-master :shift-master])
             (not (and (st/focused old) (= (st/focused old) os-focus))))
    (unless (= (st/current-ws s) (st/current-ws old))
      (errorf "E12 reordered while the focused window is not the OS-focused one: %q"
              event))))

(defn check-external [old r event]
  # E10c: a snapshot may clear external only by adopting the observed OS focus
  (when (and (old :external-focus) (= (get event 0) :windows-observed)
             (not ((r :state) :external-focus)))
    (unless (and ((r :state) :os-focus)
                 (= (st/focused (r :state)) ((r :state) :os-focus)))
      (errorf "E10 snapshot cleared external without adopting OS focus: %q" event)))
  # E10b: window-opened clears external only when adopting the observed focus
  (when (and (old :external-focus) (index-of (get event 0) [:window-opened :window-seen])
             (not ((r :state) :external-focus)))
    (unless (and (= (get event 1) (old :os-focus)) (old :os-focus))
      (errorf "E10 window-opened/seen cleared external without an observation: %q" event)))
  # E10: external focus is cleared only by observations of OS focus
  (when (and (old :external-focus) (non-focus-observation (get event 0))
             (not ((r :state) :external-focus)))
    (errorf "E10 external focus cleared by a non-observation: %q" event))
  # E11: while external, no :focus is derived unless the user asked for one
  # (ADR 0006 D-7d: or the OS focus rests on a parked window -- that is not a window the user chose to be in)
  (when (and ((r :state) :external-focus)
             (not (u/stray? (r :state)))
             (not (and (= (get event 0) :command)
                       (index-of (get event 1) [:focus-next :focus-prev :focus-master :goto :view]))))
    (when (find |(= (first $) :focus) (r :effects))
      (errorf "E11 stole focus while external: %q" event))))

(defn check-observed [old r event]
  # after a snapshot the model holds exactly the valid observed windows
  (when (= (get event 0) :windows-observed)
    (def obs (get event 1))
    (when (and (indexed? obs) (all |(and (indexed? $) (not (nil? (get $ 0)))) obs)
               (all |(or (number? (get $ 0)) (keyword? (get $ 0)) (string? (get $ 0))) obs)
               (all |(or (nil? (get $ 1)) (index-of (get $ 1) tags)) obs))
      (def s (r :state))
      (def good-facts |(if (dictionary? (get $ 2)) (get $ 2)))
      (def old-ids (stack-ids old))
      (def want
        (distinct
          (map first
               (filter
                 (fn [e]
                   (def f (good-facts e))
                   (cond
                     (nil? f) true
                     (cl/hidden? f) false
                     (index-of (first e) old-ids) true
                     (not= :ignore (cl/classify (old :rules) f))))
                 (let [seen (table)]   # the first occurrence of an id wins
                   (filter |(if (seen (first $)) false (put seen (first $) true)) obs))))))
      (def have (mapcat |(((s :workspaces) $) :ids) (s :tags)))
      (unless (deep= (sort (array ;want)) (sort (array ;have)))
        (errorf "R4 snapshot mismatch after %q: have %q" event have)))))

(defn check-idempotent [s event]
  (when (idempotent-kinds (get event 0))
    (def r1 (u/update s event))
    (def r2 (u/update (r1 :state) event))
    (unless (and (deep= (r1 :state) (r2 :state)) (empty? (r2 :effects)))
      (errorf "E6 not idempotent: %q -> %q" event (r2 :effects)))))

(deftest "random event sequences preserve all invariants"
  (for seed 0 300
    (def rng (math/rng seed))
    (var s (new-state rng))
    (for _ 0 150
      (def e (random-event rng))
      (def r (u/update s e))
      (check-invariants (r :state) e)
      (check-effects s r e)
      (check-external s r e)
      (check-observed s r e)
      (check-idempotent s e)
      (set s (r :state)))))

(deftest "core never throws on any event"
  (def rng (math/rng 5))
  (var s (new-state rng))
  (for _ 0 2000
    (set s ((u/update s (random-event rng)) :state)))
  (is (st/current-ws s)))

(deftest "a mirror driven only by effects never drifts from the model"
  (for seed 0 100
    (def rng (math/rng (+ 1000 seed)))
    (var s (new-state rng))
    (def mirror @{})
    (for _ 0 200
      (def e (random-event rng))
      (def r (u/update s e))
      (each fx (r :effects)
        (when (= (fx 0) :place) (put mirror (fx 1) (fx 2))))
      (set s (r :state))
      (def p (st/placements s))
      (eachk id p
        (unless (= (mirror id) (p id))
          (errorf "mirror drift for %q after %q (seed %d)" id e seed))))))

(deftest "refresh re-asserts every visible placement"
  # (this does NOT cover model-side drift -- ghosts, wrong workspace; that is
  # what :windows-observed is for, tested above via check-observed)
  (for seed 0 100
    (def rng (math/rng (+ 5000 seed)))
    (var s (new-state rng))
    (for _ 0 60 (set s ((u/update s (random-event rng)) :state)))
    (def mirror @{})
    (eachp [id r] (st/placements s)
      (put mirror id (g/rect (math/rng-int rng 100) 0 1 1))) # garbage
    (def r (u/update s [:command :refresh]))
    (each fx (r :effects)
      (when (= (fx 0) :place) (put mirror (fx 1) (fx 2))))
    (eachp [id rect] (st/placements (r :state))
      (is= rect (mirror id)))
    (is= (s :external-focus) ((r :state) :external-focus))
    (def f (st/focused (r :state)))
    (when (and f (not ((r :state) :external-focus)))
      (is (find |(= $ [:focus f]) (r :effects))))))

(deftest "R1: focus-changed and desktop-changed commute"
  # Jwno delivers them asynchronously and in either order
  (for seed 0 300
    (def rng (math/rng (+ 9000 seed)))
    (var s (st/make (first screens) tags))
    (for _ 0 40 (set s ((u/update s (random-event rng)) :state)))
    (def ids (mapcat |(((s :workspaces) $) :ids) (s :tags)))
    (unless (empty? ids)
      (def x (pick rng ids))
      (def tag (st/locate s x))
      (def a (reduce |((u/update $0 $1) :state) s
                     [[:focus-changed x] [:desktop-changed tag]]))
      (def b (reduce |((u/update $0 $1) :state) s
                     [[:desktop-changed tag] [:focus-changed x]]))
      (is= (st/current a) (st/current b))
      (is= tag (st/current a))
      (is= x (st/focused a))
      (is= x (st/focused b))
      (is (not (a :external-focus)))
      (is (not (b :external-focus))))))

(deftest "R2: echoing our own :place back as :window-moved yields nothing"
  (for seed 0 200
    (def rng (math/rng (+ 12000 seed)))
    (var s (new-state rng))
    (for _ 0 60 (set s ((u/update s (random-event rng)) :state)))
    (eachp [id rect] (st/placements s)
      (def r (u/update s [:window-moved id rect]))
      (is= [] (r :effects)))))

(deftest "R2: an app that refuses its size is re-placed a bounded number of times"
  (var s (st/make (first screens) tags))
  (set s ((u/update s [:window-opened :a]) :state))
  (var places 0)
  (for _ 0 20
    # the app keeps reporting a rect different from the model's
    (def r (u/update s [:window-moved :a (g/rect 1 2 3 4)]))
    (set s (r :state))
    (+= places (length (r :effects))))
  (is= 3 places)
  # a refresh clears the verdict
  (set s ((u/update s [:command :refresh]) :state))
  (is= 1 (length ((u/update s [:window-moved :a (g/rect 1 2 3 4)]) :effects))))

(deftest "S1/E13: observing focus on a visible managed window makes it actionable"
  (for seed 0 300
    (def rng (math/rng (+ 15000 seed)))
    (var s (st/make (first screens) tags))
    (for _ 0 40 (set s ((u/update s (random-event rng)) :state)))
    (def vis ((st/current-ws s) :ids))
    (unless (empty? vis)
      (def x (pick rng vis))
      (def s2 ((u/update s [:focus-changed x]) :state))
      (is= x (st/focused s2))
      (is= [[:close x]] ((u/update s2 [:command :close]) :effects)))))

(deftest "S1/E13: focus reported before window-opened is adopted"
  (for seed 0 100
    (def rng (math/rng (+ 16000 seed)))
    (var s (st/make (first screens) tags))
    (for _ 0 30 (set s ((u/update s (random-event rng)) :state)))
    (def n (keyword "fresh" seed))
    (def s2 (reduce |((u/update $0 $1) :state) s [[:focus-changed n] [:window-opened n]]))
    (is= [[:close n]] ((u/update s2 [:command :close]) :effects))))

(deftest "S2: dropping every :focus effect never lets close hit an unseen window"
  # the OS ignores all our :focus; it only ever reports what it really did
  (for seed 0 200
    (def rng (math/rng (+ 17000 seed)))
    (var s (new-state rng))
    (for _ 0 150
      (def e (random-event rng))
      (def r (u/update s e))
      (each fx (r :effects)
        (when (= (first fx) :close)
          # the real OS focus is exactly what we last observed
          (is= (fx 1) (s :os-focus))))
      (set s (r :state)))))

(deftest "T2: focus and snapshot commute (startup and reload)"
  (for seed 0 300
    (def rng (math/rng (+ 20000 seed)))
    (var s (st/make (first screens) tags))
    (for _ 0 30 (set s ((u/update s (random-event rng)) :state)))
    (def x (keyword "obs" (math/rng-int rng 6)))
    (def snap [:windows-observed
               (tuple ;(seq [i :range [0 (+ 1 (math/rng-int rng 4))]]
                         [(keyword "obs" i) (st/current s)]) [x (st/current s)])])
    (def run2 |(reduce (fn [acc e] ((u/update acc e) :state)) s $))
    (def a (run2 [[:focus-changed x] snap]))
    (def b (run2 [snap [:focus-changed x]]))
    (is= x (st/focused a))
    (is= x (st/focused b))
    (is (not (a :external-focus)))
    (is (not (b :external-focus)))
    (is= [[:close x]] ((u/update a [:command :close]) :effects))
    (is= [[:close x]] ((u/update b [:command :close]) :effects))))

(deftest "F9: toggle-float keeps stack order and focus; twice is the identity"
  (for seed 0 300
    (def rng (math/rng (+ 30000 seed)))
    (var s (new-state rng))
    (for _ 0 40 (set s ((u/update s (random-event rng)) :state)))
    (def vis ((st/current-ws s) :ids))
    (unless (empty? vis)
      (def s1 ((u/update s [:focus-changed (pick rng vis)]) :state))
      (def r1 (u/update s1 [:command :toggle-float]))
      (def r2 (u/update (r1 :state) [:command :toggle-float]))
      (is= (st/current-ws s1) (let [w (st/current-ws (r2 :state))] w))
      (is= (s1 :floating) ((r2 :state) :floating))
      (is= ((st/current-ws s1) :ids) ((st/current-ws (r1 :state)) :ids))
      (is= (st/focused s1) (st/focused (r1 :state)))
      (is (empty? (filter |(= (first $) :focus) (r1 :effects))))
      (is (not= (st/floating? s1 (st/focused s1)) (st/floating? (r1 :state) (st/focused s1)))))))

(deftest "F6: a user toggle survives repeated window-seen with the same facts"
  (def plain {:class "K" :exe "C:\\x\\c.exe" :visible? true})
  (for seed 0 100
    (def rng (math/rng (+ 31000 seed)))
    (var s (new-state rng))
    (def id :target)
    (set s ((u/update s [:window-seen id plain]) :state))
    (set s ((u/update s [:focus-changed id]) :state))
    (when (st/locate s id)
      (def was (st/floating? s id))
      (set s ((u/update s [:command :toggle-float]) :state))
      (is= (not was) (st/floating? s id))
      (for _ 0 5
        (set s ((u/update s [:window-seen id plain]) :state))
        (set s ((u/update s [:windows-observed [[id (st/locate s id) plain]]]) :state)))
      (is= (not was) (st/floating? s id)))))

(deftest "F1: a closed window's id is new again (HWND reuse)"
  (var s (st/make (first screens) tags [{:match {:exe "a.exe"} :action :float}]))
  (def fl {:exe "C:\\x\\a.exe" :visible? true})
  (set s ((u/update s [:window-seen :w fl]) :state))
  (is (st/floating? s :w))
  (set s ((u/update s [:window-closed :w]) :state))
  (is (not (st/floating? s :w)))
  (is (not (st/locate s :w)))
  (set s ((u/update s [:window-seen :w {:exe "C:\\x\\c.exe" :visible? true}]) :state))
  (is (not (st/floating? s :w)))
  (is (st/locate s :w)))

(deftest "D2: dragging a tile to exactly where we put it never floats it (a click on the title bar)"
  (for seed 0 200
    (def rng (math/rng (+ 40000 seed)))
    (var s (new-state rng))
    (for _ 0 40 (set s ((u/update s (random-event rng)) :state)))
    (eachp [id rect] (st/placements s)
      (def r (u/update s [:window-dragged id rect]))
      (is (not (st/floating? (r :state) id)))
      # no effect for the drag itself; the one thing allowed is the D-7 correction of a focus that rests on a parked
      # window (a stale :misfit being dropped makes the state "changed", and then that correction applies)
      (is= [] (tuple ;(filter |(not (and (index-of (first $) [:focus :focus-none]) (u/stray? s))) (r :effects)))))))

(deftest "D1: a moved tile floats and the rest still tile the screen without gaps"
  (for seed 0 200
    (def rng (math/rng (+ 41000 seed)))
    (var s (new-state rng))
    (for _ 0 40 (set s ((u/update s (random-event rng)) :state)))
    (def tiles (keys (st/placements s)))
    (unless (empty? tiles)
      (def id (pick rng tiles))
      (def r (u/update s [:window-dragged id (g/rect 7 9 33 21)]))
      (is (st/floating? (r :state) id))
      (check-invariants (r :state) [:window-dragged id])
      # a second identical drag changes nothing
      (is= (r :state) ((u/update (r :state) [:window-dragged id (g/rect 7 9 33 21)]) :state)))))

(deftest "H-c: the set of windows on screen, rebuilt from hide/show effects alone, is always the visible workspace"
  (for seed 0 200
    (def rng (math/rng (+ 50000 seed)))
    (var s (new-state rng))
    (def on-screen @{})                     # what a shell that obeys the effects would show
    (for step 0 150
      (def e (random-event rng))
      (def r (u/update s e))
      (def s2 (r :state))
      (def old-all (stack-ids s))
      (def new-all (stack-ids s2))
      (each fx (r :effects)
        (case (first fx)
          :hide (put on-screen (fx 1) nil)
          :show (put on-screen (fx 1) true)))
      (each id (keys on-screen) (unless (index-of id new-all) (put on-screen id nil)))   # closed / gone
      (def want (sort (array ;(vis-of s2))))
      (def have (sort (array ;(keys on-screen))))
      (unless (deep= want have)
        (errorf "H-c on-screen %q != visible %q after %q (seed %d step %d)" have want e seed step))
      (set s s2))))

(deftest "refresh also re-asserts every hidden window"
  (for seed 0 100
    (def rng (math/rng (+ 51000 seed)))
    (var s (new-state rng))
    (for _ 0 60 (set s ((u/update s (random-event rng)) :state)))
    (def r (u/update s [:command :refresh]))
    (def hidden (sort (array ;(filter |(not (index-of $ (vis-of s))) (stack-ids s)))))
    (def got (sort (array ;(map |($ 1) (filter |(= (first $) :hide) (r :effects))))))
    (is= hidden got)))
