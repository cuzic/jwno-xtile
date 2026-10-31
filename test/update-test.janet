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
  (is= [[:place :a screen] [:focus :a]] fx)
  (is= [:a] (ids s)))

(deftest "second window becomes master; only changed rects are placed"
  (def [s fx] (run (fresh) [:window-opened :a] [:window-opened :b]))
  (is= [:b :a] (ids s))
  (is= [[:place :b (g/rect 0 0 500 600)]
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
  (is= "2" ((r :state) :current))
  (is= [[:goto "2"] [:place :a screen] [:focus :a]] (r :effects)))

(deftest "goto the current or an unknown workspace is a no-op"
  (def s (fresh))
  (is= [] ((u/update s [:command :goto "1"]) :effects))
  (is= s ((u/update s [:command :goto "99"]) :state)))

(deftest "desktop-changed from the OS switches silently"
  (def [s _] (run (fresh) [:window-opened :a "2"]))
  (def r (u/update s [:desktop-changed "2"]))
  (is= "2" ((r :state) :current))
  (is= [[:place :a screen]] (r :effects)))

(deftest "send moves the focused window away and re-tiles"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]
                  [:focus-changed :b]))
  (def r (u/update s [:command :send "2"]))
  (is= [:a] (ids (r :state)))
  (is= "1" ((r :state) :current))
  (is= [[:send :b "2"] [:place :a screen] [:focus :a]] (r :effects)))

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
  (is= "1" ((r :state) :current))
  (is= [] (r :effects)))

(deftest "refresh re-emits every placement and the focus"
  (def [s _] (run (fresh) [:window-opened :a] [:window-opened :b]))
  (def r (u/update s [:command :refresh]))
  (is= [[:place :b (g/rect 0 0 500 600)]
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
  (is= [[:place :a screen]] (r :effects))
  (is= [] ((u/update (r :state) [:command :close]) :effects)))

(deftest "goto marks focus external until the OS confirms it"
  (def [s _] (run (fresh) [:window-opened :a "2"]))
  (def r (u/update s [:command :goto "2"]))
  (is ((r :state) :external-focus))
  (is= [[:goto "2"] [:place :a screen] [:focus :a]] (r :effects))
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
