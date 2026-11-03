(use ./t)
(import ../src/core/geometry :as g)
(import ../src/core/state :as st)
(import ../src/core/update :as u)

(def screen (g/rect 0 0 1000 600))
(defn fresh [] (st/make screen ["1" "2" "3"]))

(defn run
  "Fold events through update; return [final-state effects-of-last-event]."
  [s & events]
  (var cur s)
  (var fx [])
  (each e events
    (def r (u/update cur e))
    (set cur (r :state))
    (set fx (r :effects)))
  [cur fx])

(defn ids [s] ((st/current-ws s) :ids))

(deftest "first window fills the screen and takes focus"
  (def [s fx] (run (fresh) [:window-opened :a]))
  (is= [[:show :a] [:place :a screen] [:focus :a]] fx)
  (is= [:a] (ids s)))

(deftest "second window becomes master; only changed rects are placed"
  (def [s fx] (run (fresh) [:window-opened :a] [:window-opened :b]))
  (is= [:b :a] (ids s))
  (is= [[:show :b]
        [:place :b (g/rect 0 0 500 600)]
        [:place :a (g/rect 500 0 500 600)]
        [:focus :b]]
       fx))

(deftest "re-announcing a known window changes nothing"
  (def [s _] (run (fresh) [:window-opened :a]))
  (def r (u/update s [:window-opened :a]))
  (is= s (r :state))
  (is= [] (r :effects)))

(deftest "closing a window re-tiles the rest and refocuses"
  (def [s fx] (run (fresh) [:window-opened :a] [:window-opened :b]
                   [:window-closed :b]))
  (is= [:a] (ids s))
  (is= [[:place :a screen] [:focus :a]] fx))

(deftest "closing an unknown window is a no-op"
  (def [s fx] (run (fresh) [:window-closed :zzz]))
  (is= [] fx))

(deftest "focus-changed from the OS updates the model silently"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]))
  (def r (u/update s [:focus-changed :a]))
  (is= :a (st/focused (r :state)))
  (is= [] (r :effects)))

(deftest "focus-next emits a focus effect and no placements"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]))
  (def r (u/update s [:command :focus-next]))
  (is= [[:focus :a]] (r :effects)))

(deftest "swap-master re-tiles"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]
                  [:focus-changed :a]))
  (def r (u/update s [:command :swap-master]))
  (is= [:a :b] (ids (r :state)))
  (is= [[:place :a (g/rect 0 0 500 600)] [:place :b (g/rect 500 0 500 600)]]
       (r :effects)))

(deftest "expand widens the master column"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]))
  (def r (u/update s [:command :expand]))
  (is= 530 (((st/placements (r :state)) :b) :w)))

(deftest "next-layout cycles tall -> wide -> full -> tall"
  (def [s _] (run (fresh) [:command :next-layout]))
  (is= :wide ((st/current-ws s) :layout))
  (def [s _] (run s [:command :next-layout] [:command :next-layout]))
  (is= :tall ((st/current-ws s) :layout)))

(deftest "goto emits [:goto] and focuses the target's window"
  (def [s _] (run (fresh) [:window-opened :a "2"]))
  (def r (u/update s [:command :goto "2"]))
  (is= "2" (st/current (r :state)))
  (is= [[:goto "2"] [:show :a] [:place :a screen] [:focus :a]] (r :effects)))

(deftest "goto the current or an unknown workspace is a no-op"
  (def s (fresh))
  (is= [] ((u/update s [:command :goto "1"]) :effects))
  (is= s ((u/update s [:command :goto "99"]) :state)))

(deftest "desktop-changed from the OS switches silently"
  (def [s _] (run (fresh) [:window-opened :a "2"]))
  (def r (u/update s [:desktop-changed "2"]))
  (is= "2" (st/current (r :state)))
  (is= [[:show :a] [:place :a screen]] (r :effects)))

(deftest "send moves the focused window away and re-tiles"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]
                  [:focus-changed :b]))
  (def r (u/update s [:command :send "2"]))
  (is= [:a] (ids (r :state)))
  (is= "1" (st/current (r :state)))
  (is= [[:send :b "2"] [:hide :b] [:place :a screen] [:focus :a]] (r :effects)))

(deftest "send with no focused window does nothing"
  (def s (fresh))
  (is= [] ((u/update s [:command :send "2"]) :effects)))

(deftest "close asks the shell to close the focused window, state untouched"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed :a]))
  (def r (u/update s [:command :close]))
  (is= s (r :state))
  (is= [[:close :a]] (r :effects)))

(deftest "screen-changed re-places everything"
  (def [s _] (run (fresh) [:window-opened :a]))
  (def big (g/rect 0 0 2000 1000))
  (def r (u/update s [:screen-changed big]))
  (is= [[:place :a big]] (r :effects)))

(deftest "unknown events and commands are ignored"
  (def s (fresh))
  (is= [] ((u/update s [:bogus]) :effects))
  (is= [] ((u/update s [:command :bogus]) :effects)))

(deftest "opening a window for an invalid workspace is ignored"
  (def s (fresh))
  (is= s ((u/update s [:window-opened :a "nope"]) :state)))

(deftest "focus on an unmanaged window makes close/send/swap no-ops"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]
                  [:focus-changed :zzz-dialog]))
  (is (s :external-focus))
  (each cmd [[:command :close] [:command :send "2"] [:command :swap-master]
             [:command :swap-next] [:command :shift-master]]
    (def r (u/update s cmd))
    (is= [] (r :effects))
    (is= s (r :state))))

(deftest "focus-changed to nil (desktop/taskbar) is external focus too"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed nil]))
  (is= [] ((u/update s [:command :close]) :effects)))

(deftest "focusing a managed window clears external focus"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed nil]
                  [:focus-changed :a]))
  (is= [[:close :a]] ((u/update s [:command :close]) :effects)))

(deftest "focus-next after external focus brings a window back with :focus"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed nil]))
  (def r (u/update s [:command :focus-next]))
  (is= [[:focus :a]] (r :effects)))

(deftest "focus-changed to a window on another workspace never switches view"
  (def [s _] (run (fresh) [:window-opened :a "2"] [:window-opened :b]))
  (def r (u/update s [:focus-changed :a]))
  (is= "1" (st/current (r :state)))
  (is= [] (r :effects)))

(deftest "refresh re-emits every placement and the focus"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]))
  (def r (u/update s [:command :refresh]))
  (is= [[:show :b] [:show :a]
        [:place :b (g/rect 0 0 500 600)]
        [:place :a (g/rect 500 0 500 600)]
        [:focus :b]]
       (r :effects)))

(deftest "window-moved re-places only when the observed rect differs"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]))
  (def model (g/rect 500 0 500 600))
  (is= [[:place :a model]]
       ((u/update s [:window-moved :a (g/rect 0 0 10 10)]) :effects))
  (is= [] ((u/update s [:window-moved :a model]) :effects))
  (is= [] ((u/update s [:window-moved :zzz model]) :effects))
  (is= [] ((u/update s [:window-moved :a]) :effects)))

(deftest "R1 regression: focus arrives before the desktop switch"
  (def [s _] (run (fresh) [:window-opened :b "2"] [:window-opened :c "2"]))
  # model focus on ws 2 is :c; user clicks :b on the taskbar
  (def [s _] (run s [:focus-changed :b] [:desktop-changed "2"]))
  (is= :b (st/focused s))
  (is (not (s :external-focus)))
  (is= [[:close :b]] ((u/update s [:command :close]) :effects)))

(deftest "R1 regression: until the switch is observed, close does nothing"
  (def [s _] (run (fresh) [:window-opened :b "2"] [:focus-changed :b]))
  (is (s :external-focus))
  (is= [] ((u/update s [:command :close]) :effects)))

(deftest "R3 regression: refresh neither clears external focus nor steals focus"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed nil]))
  (def r (u/update s [:command :refresh]))
  (is ((r :state) :external-focus))
  (is= [[:show :a] [:place :a screen]] (r :effects))
  (is= [] ((u/update (r :state) [:command :close]) :effects)))

(deftest "goto marks focus external until the OS confirms it"
  (def [s _] (run (fresh) [:window-opened :a "2"]))
  (def r (u/update s [:command :goto "2"]))
  (is ((r :state) :external-focus))
  (is= [[:goto "2"] [:show :a] [:place :a screen] [:focus :a]] (r :effects))
  (def r2 (u/update (r :state) [:focus-changed :a]))
  (is (not ((r2 :state) :external-focus))))

(deftest "windows-observed repairs ghosts, missing windows and wrong workspaces"
  (def [s _] (run (fresh) [:window-opened :ghost] [:window-opened :a]
                  [:window-opened :moved "2"]))
  (def r (u/update s [:windows-observed [[:a "1"] [:moved "1"] [:new "3"]]]))
  (def s2 (r :state))
  (is= nil (st/locate s2 :ghost))
  (is= "1" (st/locate s2 :moved))
  (is= "3" (st/locate s2 :new))
  (is= "1" (st/locate s2 :a)))

(deftest "ill-typed and mutable values never reach the state"
  (def s (fresh))
  (each ev [[:screen-changed 5] [:screen-changed {:x 0 :y 0 :w -5 :h 10}]
            [:window-opened @[1]] [:window-opened :z @"1"]]
    (is= s ((u/update s ev) :state))))

(deftest "malformed events are ignored, never thrown"
  (def s (fresh))
  (each ev [[] [:window-opened] [:command] nil 42 "x"]
    (def r (u/update s ev))
    (is= s (r :state))
    (is= [] (r :effects))))

(deftest "S1: focus on a brand-new hwnd arrives before window-opened"
  # Jwno fires :focus-changed for an unknown hwnd, then :window-opened, and
  # never repeats the focus notification
  (def [s _] (run (fresh) [:focus-changed :n] [:window-opened :n]))
  (is (not (s :external-focus)))
  (is= [[:close :n]] ((u/update s [:command :close]) :effects)))

(deftest "S1: a different window opening does not adopt someone else's focus"
  (def [s _] (run (fresh) [:focus-changed :n] [:window-opened :other]))
  (is (s :external-focus))
  (is= [] ((u/update s [:command :close]) :effects)))

(deftest "S2: a failed :focus can never make close hit the wrong window"
  # focus-next moves the model to :b and emits [:focus :b]; the OS refuses
  # (foreground lock) and never reports a focus change. :a is still on screen.
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]
                  [:focus-changed :a]))
  (def r (u/update s [:command :focus-next]))
  (is= :b (st/focused (r :state)))
  (is= [[:focus :b]] (r :effects))
  (is= [] ((u/update (r :state) [:command :close]) :effects))
  (is= [] ((u/update (r :state) [:command :send "2"]) :effects))
  (is= (r :state) ((u/update (r :state) [:command :swap-master]) :state))
  # once the OS confirms, it works
  (def [s2 _] (run (r :state) [:focus-changed :b]))
  (is= [[:close :b]] ((u/update s2 [:command :close]) :effects)))

(deftest "S2: closing the focused window leaves nothing to act on until observed"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]
                  [:focus-changed :b] [:window-closed :b]))
  (is= :a (st/focused s))
  (is= [] ((u/update s [:command :close]) :effects)))

(deftest "S3: windows-observed keeps the given order, first = master, no focus move"
  (def r (u/update (fresh) [:windows-observed [[:top "1"] [:mid "1"] [:bot "1"]]]))
  (is= [:top :mid :bot] (ids (r :state)))
  (is (empty? (filter |(= (first $) :focus) (r :effects)))))

(deftest "S4: a nil tag in a snapshot leaves a known window where it is"
  (def [s _] (run (fresh) [:window-opened :b "2"]))
  (def s2 ((u/update s [:windows-observed [[:b nil]]]) :state))
  (is= "2" (st/locate s2 :b)))

(deftest "S5: windows-observed does not steal focus from what the OS focused"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed :a]))
  (def r (u/update s [:windows-observed [[:a "1"] [:x "1"]]]))
  (is= :a (st/focused (r :state)))
  (is (empty? (filter |(= (first $) :focus) (r :effects)))))

(deftest "S7: closing a window forgets its misfit verdict (HWND reuse)"
  (def [s _] (run (fresh) [:window-opened :a]))
  (var s2 s)
  (for _ 0 5 (set s2 ((u/update s2 [:window-moved :a (g/rect 1 2 3 4)]) :state)))
  (def [s3 _] (run s2 [:window-closed :a] [:window-opened :a]))
  (is= 1 (length ((u/update s3 [:window-moved :a (g/rect 1 2 3 4)]) :effects))))

(deftest "S9: tags must be strings"
  (is (not (first (protect (st/make screen [:one :two]))))))

# ---- ADR 0009: :pending-focus / :reassert-focus ------------------------

(defn after-goto
  "Windows a on 1; b, c on 2 (c focused); the user went to 2. -> state"
  []
  (def [s _] (run (fresh)
                  [:window-opened :a]
                  [:window-opened :b "2"] [:window-opened :c "2"]
                  [:focus-changed :a]
                  [:command :goto "2"]))
  s)

(deftest "goto remembers what it wanted focused"
  (def s (after-goto))
  (is= {:target :c :tag "2"} (s :pending-focus))
  (def [_ fx] (run (fresh) [:window-opened :a] [:window-opened :c "2"] [:focus-changed :a]
                   [:command :goto "2"]))
  (is= [:goto "2"] (first fx))
  (is= [:focus :c] (last fx)))

(deftest "goto onto an empty workspace remembers nothing"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed :a] [:command :goto "3"]))
  (is (nil? (s :pending-focus))))

(deftest "reassert: Jwno overrode us with another ordinary window -> ask for ours again, once"
  (def [s1 _] (run (after-goto) [:focus-changed :b]))   # the override, observed
  (is= :b (s1 :os-focus))
  (def r (u/update s1 [:command :reassert-focus]))
  (is= [[:focus :c]] (tuple ;(r :effects)))
  (is= :c (st/focused (r :state)))
  (is= :b ((r :state) :os-focus))               # not confirmed yet: close stays disabled
  (is (nil? ((r :state) :pending-focus)))
  (is= [] (tuple ;((u/update (r :state) [:command :reassert-focus]) :effects)))   # at most once
  (is= [] (tuple ;((u/update (r :state) [:command :close]) :effects))))

(deftest "reassert does nothing when the OS is already on the target, or nothing is pending"
  (def s0 (after-goto))
  (is= [] (tuple ;((u/update s0 [:command :reassert-focus]) :effects)))     # os-focus unknown / external
  (def [s1 _] (run s0 [:focus-changed :c]))
  (is (nil? (s1 :pending-focus)))                                           # success consumed it
  (is= [] (tuple ;((u/update s1 [:command :reassert-focus]) :effects)))
  (is= [] (tuple ;((u/update (fresh) [:command :reassert-focus]) :effects))))

(deftest "reassert never takes focus from an unmanaged window or a floating dialog"
  (def s0 (after-goto))
  (def [unmanaged _] (run s0 [:focus-changed :stranger]))
  (is= [] (tuple ;((u/update unmanaged [:command :reassert-focus]) :effects)))
  (is= unmanaged ((u/update unmanaged [:command :reassert-focus]) :state))
  (def with-rules (st/make screen ["1" "2" "3"] [{:match {:class "#32770"} :action :float}]))
  (def [s1 _] (run with-rules
                   [:window-opened :a]
                   [:window-seen :dlg {:class "#32770" :visible? true} "2"]
                   [:window-opened :c "2"]
                   [:focus-changed :a] [:command :goto "2"]
                   [:focus-changed :dlg]))
  (is (st/floating? s1 :dlg))
  (is (s1 :pending-focus))
  (is= [] (tuple ;((u/update s1 [:command :reassert-focus]) :effects))))

(deftest "reassert ignores arguments"
  (def [s1 _] (run (after-goto) [:focus-changed :b]))
  (is= [] (tuple ;((u/update s1 [:command :reassert-focus :c]) :effects))))

(deftest "pending is dropped by a new intent, a manual switch, the target going away, or a new window"
  (def s0 (after-goto))
  (is (nil? (((u/update s0 [:command :focus-next]) :state) :pending-focus)))
  (is (nil? (((u/update s0 [:command :close]) :state) :pending-focus)))
  (is (nil? (((u/update s0 [:desktop-changed "3"]) :state) :pending-focus)))
  (is (nil? (((u/update s0 [:window-closed :c]) :state) :pending-focus)))
  (is (nil? (((u/update s0 [:window-opened :n]) :state) :pending-focus)))   # core gave n the focus
  # but observing the override does not: that is what we repair
  (is (((u/update s0 [:focus-changed :b]) :state) :pending-focus))
  (is (((u/update s0 [:desktop-changed "2"]) :state) :pending-focus)))   # our own goto, confirmed by the OS

# ---- ADR 0008 addendum: [:window-dragged id rect] ----------------------

(defn tiled-state
  "a, b, c on workspace 1 (Tall, 1000x600): c master. -> state"
  []
  ((run (fresh) [:window-opened :a] [:window-opened :b] [:window-opened :c]) 0))

(deftest "dragged to a different rect: the window floats where it was dropped, the rest re-tile"
  (def s (tiled-state))
  (def moved {:x 40 :y 50 :w 300 :h 200})
  (def r (u/update s [:window-dragged :b moved]))
  (is (st/floating? (r :state) :b))
  (is= (st/focused s) (st/focused (r :state)))                         # focus untouched
  (is= ((st/current-ws s) :ids) ((st/current-ws (r :state)) :ids))     # order untouched
  (is (not (find |(and (= (first $) :place) (= (get $ 1) :b)) (r :effects))))   # never placed again
  (is (find |(= (first $) :place) (r :effects))))                      # the others fill the gap

(deftest "dragged to the SAME rect (a click on the title bar): nothing becomes floating"
  (def s (tiled-state))
  (def here ((st/placements s) :b))
  (def r (u/update s [:window-dragged :b here]))
  (is (not (st/floating? (r :state) :b)))
  (is= s (r :state))
  (is= [] (tuple ;(r :effects))))

(deftest "dragging clears a stale misfit count, and is idempotent"
  (def s (tiled-state))
  (def far {:x 1 :y 1 :w 10 :h 10})
  (def [s1 _] (run s [:window-moved :b far] [:window-moved :b far]))
  (is (get-in s1 [:misfit :b]))
  (def r1 (u/update s1 [:window-dragged :b far]))
  (is (nil? (get-in (r1 :state) [:misfit :b])))
  (def r2 (u/update (r1 :state) [:window-dragged :b far]))
  (is= (r1 :state) (r2 :state))
  (is= [] (tuple ;(r2 :effects))))

(deftest "dragged: unknown, invalid, already floating, ignored and other-workspace windows change nothing"
  (def s (tiled-state))
  (def far {:x 1 :y 1 :w 10 :h 10})
  (each ev [[:window-dragged :nope far] [:window-dragged :b] [:window-dragged :b "x"]
            [:window-dragged :b {:x 0 :y 0 :w -1 :h 5}] [:window-dragged @[1] far] [:window-dragged nil far]]
    (is= s ((u/update s ev) :state)))
  (def [s2 _] (run (fresh) [:window-opened :a] [:window-opened :z "2"]))
  (is= s2 ((u/update s2 [:window-dragged :z far]) :state))             # not on the visible workspace
  (def [s3 _] (run s [:command :toggle-float]))                         # nothing is focused-and-observed: no-op
  (def [s4 _] (run s [:focus-changed :b] [:command :toggle-float]))
  (is (st/floating? s4 :b))
  (is= s4 ((u/update s4 [:window-dragged :b far]) :state)))

(deftest "dragging never lowers :external-focus and does not touch the OS focus record"
  (def [s _] (run (tiled-state) [:focus-changed :b]))
  (def r (u/update s [:window-dragged :a {:x 1 :y 1 :w 10 :h 10}]))
  (is= (s :os-focus) ((r :state) :os-focus))
  (is= (s :external-focus) ((r :state) :external-focus)))

# ---- ADR 0006: [:hide id] / [:show id] ---------------------------------

(defn kinds [fx kind] (map |($ 1) (filter |(= (first $) kind) fx)))

(deftest "goto hides what leaves and shows what enters; hide comes first, focus last"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]
                  [:window-opened :c "2"] [:window-opened :d "2"]))
  (def r (u/update s [:command :goto "2"]))
  (def fx (tuple ;(r :effects)))
  (is= [:goto "2"] (first fx))
  (is= [:b :a] (tuple ;(kinds fx :hide)))                       # the old workspace, in stack order
  (is= [:d :c] (tuple ;(kinds fx :show)))
  (defn pos [kind] (find-index |(= (first $) kind) fx))
  (is (< (pos :hide) (pos :show)))
  (is (< (pos :show) (pos :place)))
  (is= :focus (first (last fx)))
  # and back
  (def r2 (u/update (r :state) [:command :goto "1"]))
  (is= [:d :c] (tuple ;(kinds (r2 :effects) :hide)))
  (is= [:b :a] (tuple ;(kinds (r2 :effects) :show))))

(deftest "a floating window is shown without a :place"
  (def rules [{:match {:class "#32770"} :action :float}])
  (def s0 (st/make screen ["1" "2" "3"] rules))
  (def [s _] (run s0 [:window-opened :t "2"] [:window-seen :dlg {:class "#32770" :visible? true} "2"]))
  (def r (u/update s [:command :goto "2"]))
  (is (find |(= $ [:show :dlg]) (r :effects)))
  (is (not (find |(and (= (first $) :place) (= (get $ 1) :dlg)) (r :effects)))))

(deftest "send hides the window that leaves; the others re-tile; it is never placed"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b] [:focus-changed :b]))
  (def r (u/update s [:command :send "2"]))
  (is= [:b] (tuple ;(kinds (r :effects) :hide)))
  (is= [] (tuple ;(kinds (r :effects) :show)))
  (is (not (find |(and (= (first $) :place) (= (get $ 1) :b)) (r :effects)))))

(deftest "windows that merely disappear are never hidden: closed, minimised, or ghosts"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b] [:window-opened :c]))
  (is= [] (tuple ;(kinds ((u/update s [:window-closed :b]) :effects) :hide)))
  (is= [] (tuple ;(kinds ((u/update s [:window-seen :b {:minimized? true}]) :effects) :hide)))
  (is= [] (tuple ;(kinds ((u/update s [:windows-observed [[:a nil] [:c nil]]]) :effects) :hide))))

(deftest "a window that appears on a workspace we are not looking at is on screen, so it is hidden at once"
  (def [s _] (run (fresh) [:window-opened :a]))
  (def r (u/update s [:window-opened :z "3"]))
  (is= [:z] (tuple ;(kinds (r :effects) :hide)))
  (is= [] (tuple ;(kinds (r :effects) :show))))

(deftest "ADR 0006 D-6: a new window on the visible workspace IS 'shown' (it may be a forgotten parked one)"
  (def [s _] (run (fresh) [:window-opened :a]))
  (def r (u/update s [:window-opened :b]))
  (is= [:b] (tuple ;(kinds (r :effects) :show)))
  (is= [] (tuple ;(kinds (r :effects) :hide))))

(deftest "refresh re-asserts every hidden window as well"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :c "2"] [:window-opened :d "3"]))
  (def r (u/update s [:command :refresh]))
  (is= [:c :d] (tuple ;(sort (array ;(kinds (r :effects) :hide))))))

# ---- ADR 0006 D-7: the OS focus must not rest on a parked window ----------------------------

(deftest "D-7: goto an empty workspace keeps :os-focus and asks for no focus (focus-none)"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed :a]))
  (def r (u/update s [:command :goto "2"]))
  (is= :a ((r :state) :os-focus))                                  # still observed: the front window really is :a
  (is= [[:goto "2"] [:hide :a] [:focus-none]] (r :effects)))

(deftest "D-7: the last window sent away leaves no focus on it"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed :a]))
  (def r (u/update s [:command :send "2"]))
  (is= [[:send :a "2"] [:hide :a] [:focus-none]] (r :effects)))

(deftest "D-7: a window of the visible workspace is focused instead when there is one"
  (def [s _] (run (fresh) [:window-opened :a "2"] [:window-opened :b] [:focus-changed :b]))
  # the OS now rests on a parked window of workspace 2 (e.g. the user picked it in the taskbar)
  (def s2 ((u/update s [:focus-changed :a]) :state))
  (def r (u/update s2 [:command :reclaim-focus]))
  (is= [[:focus :b :reclaim]] (r :effects)))

(deftest "D-7/F12b: an unknown window (a dialog, the start menu) is never taken from"
  (def [s _] (run (fresh) [:window-opened :a] [:focus-changed :a]))
  (def s2 ((u/update s [:focus-changed :dialog]) :state))
  (is= [] ((u/update s2 [:command :reclaim-focus]) :effects))
  (def [s3 _] (run (fresh) [:window-opened :a "2"] [:focus-changed nil]))
  (is= [] ((u/update s3 [:command :reclaim-focus]) :effects)))

(deftest "D-7: closing the last window, in either order of arrival, ends with focus-none"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :p "2"] [:focus-changed :a]))
  # order 1: the OS hands the focus to the parked :p first, then :a is reported closed
  (def o1 (-> s (u/update [:focus-changed :p]) (get :state) (u/update [:window-closed :a])))
  (is= [[:focus-none]] (o1 :effects))
  # order 2: closed first, the focus change arrives afterwards (silent): the reclaim command settles it
  (def o2a ((u/update s [:window-closed :a]) :state))
  (def o2b ((u/update o2a [:focus-changed :p]) :state))
  (is= [] ((u/update o2a [:focus-changed :p]) :effects))
  (is= [[:focus-none :reclaim]] ((u/update o2b [:command :reclaim-focus]) :effects)))

(deftest "D-7: the reclaim command tries 3 times, then gives up with a notify, and the count is per window"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :p "2"] [:window-opened :q "2"] [:focus-changed :a]))
  (var st ((u/update s [:focus-changed :p]) :state))
  (def fxs @[])
  (for _ 0 5
    (def r (u/update st [:command :reclaim-focus]))
    (array/push fxs (r :effects))
    (set st (r :state)))
  (is= [[[:focus :a :reclaim]] [[:focus :a :reclaim]] [[:focus :a :reclaim]] [[:notify :reclaim-gave-up :p]] []] (tuple ;fxs))
  # a different parked window starts from zero
  (def st2 ((u/update st [:focus-changed :q]) :state))
  (is= [[:focus :a :reclaim]] ((u/update st2 [:command :reclaim-focus]) :effects))
  # the tries end once the focus is back on the visible workspace
  (def st3 ((u/update st [:focus-changed :a]) :state))
  (is (nil? (st3 :reclaim-tries))))

(deftest "D-7: the reclaim command keeps the pending :goto focus (it is not a new intent)"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b "2"] [:focus-changed :a]))
  (def r (u/update s [:command :goto "2"]))
  (is (get (r :state) :pending-focus))
  (is (get ((u/update (r :state) [:command :reclaim-focus]) :state) :pending-focus)))

(deftest "D-7e: :follow goes to the workspace of a parked window the user chose, but not after our own goto"
  (def f (st/make {:x 0 :y 0 :w 1000 :h 600} ["1" "2" "3"] [] :follow))
  (def [s _] (run f [:window-opened :a] [:window-opened :p "2"] [:focus-changed :a]))
  # the user picks :p in the taskbar
  (def chosen ((u/update s [:focus-changed :p]) :state))
  (def r (u/update chosen [:command :reclaim-focus]))
  (is= "2" (st/current (r :state)))
  (is= [[:goto "2"] [:hide :a] [:show :p] [:place :p screen] [:focus :p]] (r :effects))
  # our own goto 3 (empty) leaves :a in front; following it would undo the goto
  (def g ((u/update s [:command :goto "3"]) :state))
  (is= [[:focus-none :reclaim]] ((u/update g [:command :reclaim-focus]) :effects))
  (is= "3" (st/current ((u/update g [:command :reclaim-focus]) :state))))

(deftest "D-6: a window the core forgot and sees again gets :show (it may still be parked)"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :f "2"]))
  (def gone ((u/update s [:windows-observed []]) :state))              # forgotten
  (def r (u/update gone [:windows-observed [[:f nil]]]))              # seen again, lands on the visible workspace
  (is (find |(= $ [:show :f]) (r :effects))))

# ---- Opus M4: a window minimised on a hidden workspace goes home when it comes back ----------

(deftest "M4: minimised on workspace 2, restored while looking at workspace 1: back on workspace 2"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :p "2"]))
  (def gone ((u/update s [:windows-observed [[:a nil {:visible? true}] [:p nil {:visible? true :minimized? true}]]]) :state))
  (is (nil? (st/locate gone :p)))
  (def back ((u/update gone [:windows-observed [[:a nil {:visible? true}] [:p nil {:visible? true}]]]) :state))
  (is= "2" (st/locate back :p))
  (is (nil? (get-in back [:hidden-from :p]))))

(deftest "M4: an explicit tag beats the remembered home; a window that left the OS is forgotten; closing forgets too"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :p "2"]))
  (def gone ((u/update s [:windows-observed [[:a nil {:visible? true}] [:p nil {:visible? true :minimized? true}]]]) :state))
  (is= "3" (st/locate ((u/update gone [:window-opened :p "3"]) :state) :p))
  # the window disappeared from the OS while minimised: the memory goes with it (ids are reused)
  (def ghost ((u/update gone [:windows-observed [[:a nil {:visible? true}]]]) :state))
  (is (nil? (get-in ghost [:hidden-from :p])))
  (is= "1" (st/locate ((u/update ghost [:window-opened :p]) :state) :p))
  (is (nil? (get-in ((u/update gone [:window-closed :p]) :state) [:hidden-from :p]))))

(deftest "Opus F-H1: a window the user activated while it was minimised comes back to the workspace they are on"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :p "2"]))
  (def gone ((u/update s [:windows-observed [[:a nil {:visible? true}] [:p nil {:visible? true :minimized? true}]]]) :state))
  # restored from the taskbar: it is the OS focus now (the focus event comes before the snapshot)
  (def active ((u/update gone [:focus-changed :p]) :state))
  (def back ((u/update active [:windows-observed [[:a nil {:visible? true}] [:p nil {:visible? true}]]]) :state))
  (is= "1" (st/locate back :p))
  # a quiet restore (no activation) still goes home
  (def quiet ((u/update gone [:windows-observed [[:a nil {:visible? true}] [:p nil {:visible? true}]]]) :state))
  (is= "2" (st/locate quiet :p)))

(deftest "4e: :stray-own is not cleared by the observation of the stray window itself (a :follow must not undo our own goto)"
  (def f (st/make {:x 0 :y 0 :w 1000 :h 600} ["1" "2" "3"] [] :follow))
  (def [s _] (run f [:window-opened :a] [:focus-changed :a]))
  (def g ((u/update s [:command :goto "3"]) :state))
  (def seen ((u/update g [:focus-changed :a]) :state))                # the OS still reports :a in front
  (is= "3" (st/current ((u/update seen [:command :reclaim-focus]) :state)))
  # a different window in front ends the mark
  (def other ((u/update seen [:focus-changed :zzz]) :state))
  (is (nil? (other :stray-own))))

(deftest "F-L3: a :refresh (the runtime's recovery) keeps the reclaim bookkeeping"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :p "2"] [:focus-changed :a]))
  (def st1 ((u/update ((u/update s [:focus-changed :p]) :state) [:command :reclaim-focus]) :state))
  (is (st1 :reclaim-tries))
  (is (((u/update st1 [:command :refresh]) :state) :reclaim-tries)))

# ---- ADR 0006 rev.5b: [:window-surfaced id] -------------------------------------------------

(deftest "S-1: a window of a hidden workspace that stays on screen joins the visible workspace as a float, without a focus effect"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :m "2"] [:focus-changed :a]))
  (def r (u/update s [:window-surfaced :m]))
  (is= "1" (st/locate (r :state) :m))
  (is (st/floating? (r :state) :m))
  (is (find |(= $ [:show :m]) (r :effects)))
  (is (not (find |(index-of (first $) [:focus :focus-none :place]) (tuple ;(filter |(= (get $ 1) :m) (r :effects))))))
  (is= :a ((r :state) :os-focus))
  (is= "1" (st/current (r :state)))
  (is= false ((r :state) :external-focus)))

(deftest "S-1: unknown, malformed and already-visible windows change nothing; twice is the same as once"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :m "2"]))
  (is= s ((u/update s [:window-surfaced :nobody]) :state))
  (is= s ((u/update s [:window-surfaced :a]) :state))
  (is= s ((u/update s [:window-surfaced]) :state))
  (def once ((u/update s [:window-surfaced :m]) :state))
  (is= once ((u/update once [:window-surfaced :m]) :state)))
