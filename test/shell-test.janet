# Runtime tests against a fake OS (ADR 0009 / 0003 §8 stage 1). The fake is OUR
# guess at the port; nothing here is verified on Windows.
(use ./t)
(import ../src/core/geometry :as g)
(import ../src/core/state :as st)
(import ../src/core/update :as u)
(import ../src/shell/runtime :as rt)

(def screen (g/rect 0 0 1000 600))

(defn fake-os
  "A fake OS + its port. Knobs on the returned table: :fail (set of port names
  that throw), :focus-lock (our :focus does nothing), :log-throws."
  []
  (def os @{:fg nil :rects @{} :calls @[] :later @[] :windows @[]
            :fail @{} :focus-lock false :log-throws false :logs @[]
            :hook nil :desktop nil})
  (defn boom [name] (when ((os :fail) name) (errorf "%s failed" name)))
  (defn rec [& c] (array/push (os :calls) c))
  (put os :ctx
      {:place (fn [id r] (boom :place) (rec :place id r) (put (os :rects) id r))
       :focus (fn [id] (boom :focus) (rec :focus id)
                (unless (os :focus-lock) (put os :fg id)))
       :goto (fn [tag] (boom :goto) (rec :goto tag))
       :send (fn [id tag] (boom :send) (rec :send id tag))
       :close (fn [id] (boom :close) (rec :close id)
                (put os :windows (filter |(not= $ id) (os :windows)))
                (when (= (os :fg) id) (put os :fg nil)))
       :foreground (fn [] (boom :foreground) (os :fg))
       :foreground-is? (fn [id] (boom :foreground-is?) (= id (os :fg)))
       :enumerate (fn []
                    (when (os :hook) ((os :hook)))
                    (map |[$ nil {:visible? true}] (os :windows)))
       :current-desktop (fn [] (boom :current-desktop) (os :desktop))
       :work-area (fn [] screen)
       :later (fn [d thunk] (array/push (os :later) [d thunk]))
       :log (fn [l m]
              (when (os :log-throws) (error "log failed"))
              (array/push (os :logs) [l m]))
       :notify (fn [k id] (rec :notify k id))})
  os)

(defn make-rt [os] (rt/make (os :ctx) (st/make screen ["1" "2" "3"])))

(defn closes [os] (tuple ;(map |($ 1) (filter |(= (first $) :close) (os :calls)))))

(defn run-later!
  "Run (and drop) every scheduled thunk; -> how many ran."
  [os]
  (def ts (array ;(os :later)))
  (array/clear (os :later))
  (each [_ f] ts (f))
  (length ts))

(deftest "RT-2/R-2: state is saved before effects run"
  (def os (fake-os))
  (def r (make-rt os))
  (var seen nil)
  (var r2 nil)
  (def ctx (merge (os :ctx)
                  {:place (fn [id _] (set seen (st/locate (rt/state r2) id)))}))
  (set r2 (rt/make ctx (st/make screen ["1" "2" "3"])))
  (rt/dispatch r2 [:window-opened :a])
  (is= "1" seen))

(deftest "RT-1/R-1: dispatch from inside an effect is queued, not re-entered"
  (def os (fake-os))
  (var r nil)
  (var inner-state nil)
  (var fired false)
  (def ctx (merge (os :ctx)
                  {:place (fn [id _]
                            (unless fired
                              (set fired true)
                              (rt/dispatch r [:window-opened :b])
                              # not processed yet: we are still inside :a's batch
                              (set inner-state (st/locate (rt/state r) :b))))}))
  (set r (rt/make ctx (st/make screen ["1" "2" "3"])))
  (rt/dispatch r [:window-opened :a])
  (is= nil inner-state)
  (is= "1" (st/locate (rt/state r) :b))     # but it was processed afterwards
  (is (empty? (r :queue))))

(deftest "RT-6: a throwing port (even :log) never wedges the runtime"
  (def os (fake-os))
  (def r (make-rt os))
  (put os :log-throws true)
  (each name [:place :focus :goto :send :close :foreground :foreground-is? :enumerate]
    (put (os :fail) name true))
  (rt/dispatch r [:window-opened :a])
  (rt/dispatch r [:command :close])
  (is (not (r :busy)))
  (put (os :fail) :place nil)
  (rt/dispatch r [:window-opened :b])
  (is= "1" (st/locate (rt/state r) :b)))

(deftest "R-3: update never sees a thrown state; effects continue past a failure"
  (def os (fake-os))
  (def r (make-rt os))
  (rt/dispatch r [:window-opened :a])
  (put (os :fail) :place true)
  (rt/dispatch r [:window-opened :b])      # both :place fail; :focus must still run
  (is (find |(= $ [:focus :b]) (os :calls))))

(deftest "R-3/M4: a failed :goto means no :focus in the same batch"
  (def os (fake-os))
  (def r (make-rt os))
  (rt/dispatch r [:window-opened :a])
  (rt/dispatch r [:command :goto "2"])
  (rt/dispatch r [:window-opened :b])
  (rt/dispatch r [:command :goto "1"])
  (array/clear (os :calls))
  (put (os :fail) :goto true)
  (rt/dispatch r [:command :goto "2"])
  (is (not (find |(= (first $) :focus) (os :calls)))))

(deftest "RT-3/R-6: an owned dialog in front is closed, never its owner"
  (def os (fake-os))
  (def r (make-rt os))
  (rt/dispatch r [:window-opened :n])
  (rt/dispatch r [:window-opened :d])
  (put os :windows @[:d :n])
  (rt/dispatch r [:focus-changed :n])      # stale: the model thinks N is focused
  (put os :fg :d)                          # the user is really looking at D
  (rt/dispatch r [:command :close])
  (is= [:d] (closes os)))

(deftest "R-6: :close is dropped, and reported, when the foreground differs"
  (def os (fake-os))
  (def r (make-rt os))
  (rt/dispatch r [:window-opened :a])
  (rt/dispatch r [:focus-changed :a])
  (put os :fg :a)
  # between the pre-observation and the close the OS moves on: simulate by a
  # foreground that flips after the first read
  (var reads 0)
  (def ctx (merge (os :ctx)
                  {:foreground (fn [] (++ reads) (if (= reads 1) :a :zzz))
                   :foreground-is? (fn [id] (= id :zzz))}))
  (def r2 (rt/make ctx (rt/state r)))
  (rt/dispatch r2 [:command :close])
  (is= [] (closes os))
  (is (find |(= $ [:notify :ignored-close :a]) (os :calls))))

(deftest "RT-4: close never hits anything but the real foreground (random order/loss)"
  (for seed 0 200
    (def rng (math/rng seed))
    (def os (fake-os))
    (def r (make-rt os))
    (def ids [:a :b :c :d])
    (for _ 0 80
      (case (math/rng-int rng 7)
        0 (let [id (ids (math/rng-int rng 4))]
            (unless (find |(= $ id) (os :windows)) (array/push (os :windows) id))
            (rt/dispatch r [:window-opened id]))
        1 (put os :fg (ids (math/rng-int rng 4)))                    # user alt-tabs, no notification
        2 (rt/dispatch r [:focus-changed (ids (math/rng-int rng 4))]) # a (possibly stale) notification
        3 (put os :focus-lock (= 0 (math/rng-int rng 2)))
        4 (run-later! os)
        5 (rt/dispatch r [:command :focus-next])
        (do
          (def before (length (closes os)))
          (def fg (os :fg))
          (rt/dispatch r [:command :close])
          (each id (slice (closes os) before)
            (is= fg id)))))))

(deftest "M2: a nil re-observation after :focus/:goto does not erase a good :os-focus"
  (def os (fake-os))
  (def r (make-rt os))
  (rt/dispatch r [:window-opened :a])
  (rt/dispatch r [:focus-changed :a])
  (is= :a ((rt/state r) :os-focus))
  (put os :focus-lock true)
  (put os :fg nil)                          # the OS reads back nothing mid-switch
  (rt/dispatch r [:window-opened :b])      # emits :focus, then re-observes: nil
  (is (find |(= $ [:focus :b]) (os :calls)))
  (is= :a ((rt/state r) :os-focus)))

(deftest "R-5: a nil foreground before a command makes destructive commands stop"
  (def os (fake-os))
  (def r (make-rt os))
  (rt/dispatch r [:window-opened :a])
  (rt/dispatch r [:focus-changed :a])
  (put os :fg nil)
  (rt/dispatch r [:command :close])
  (is= [] (closes os)))

(deftest "RT-7: re-observation does not chain"
  (def os (fake-os))
  (def r (make-rt os))
  (var reads 0)
  (def ctx (merge (os :ctx) {:foreground (fn [] (++ reads) (os :fg))}))
  (def r2 (rt/make ctx (st/make screen ["1" "2" "3"])))
  (rt/dispatch r2 [:window-opened :a])
  (is (<= reads 2))
  (is (<= (length (os :later)) 1))           # one delayed re-observation, not a chain
  (def before reads)
  (run-later! os)
  (is (<= (- reads before) 1))
  (is (<= (length (os :later)) 0)))

(deftest "RT-5/H2: recovery is finite however many unrelated successes arrive"
  (def os (fake-os))
  (def r (make-rt os))
  (array/push (os :windows) :a :b)       # the snapshot must agree with the model
  (rt/dispatch r [:window-opened :a])
  (put (os :fail) :place true)
  (rt/dispatch r [:window-opened :b])
  (var recoveries 0)
  (for _ 0 60
    (each [d f] (array ;(os :later))
      (when (= d 1.0) (++ recoveries)))
    (run-later! os)
    # unrelated silent events that need no effects
    (rt/dispatch r [:focus-changed :a])
    (rt/dispatch r [:focus-changed :b]))
  (is (<= recoveries 3))
  # a successful batch re-arms recovery
  (put (os :fail) :place nil)
  (rt/dispatch r [:command :next-layout])
  (put (os :fail) :place true)
  (rt/dispatch r [:command :next-layout])
  (is (find |(= (first $) 1.0) (os :later))))

(deftest "R-8: failure schedules one recovery (observe + refresh) and it repairs"
  (def os (fake-os))
  (def r (make-rt os))
  (put (os :fail) :place true)
  (array/push (os :windows) :a)
  (rt/dispatch r [:window-opened :a])
  (is= 1 (length (filter |(= 1.0 (first $)) (os :later))))
  (rt/dispatch r [:window-opened :b])
  (is= 1 (length (filter |(= 1.0 (first $)) (os :later))))  # still one pending
  (put (os :fail) :place nil)
  (run-later! os)
  (is= screen (get (os :rects) :a)))

(deftest "R-7/M5: events arriving during start are queued and processed"
  (def os (fake-os))
  (array/push (os :windows) :a)
  (def r (make-rt os))
  # a hook fires while we enumerate
  (put os :hook (fn [] (rt/dispatch r [:window-opened :late])))
  (rt/start r)
  (is (st/locate (rt/state r) :a))
  (is= "1" (st/locate (rt/state r) :late))
  (is (not (r :busy))))

(deftest "RT-9: after notifications stop, refresh + observation make OS = model"
  (for seed 0 100
    (def rng (math/rng (+ 700 seed)))
    (def os (fake-os))
    (def r (make-rt os))
    (def ids [:a :b :c :d])
    (for _ 0 60
      (case (math/rng-int rng 6)
        0 (let [id (ids (math/rng-int rng 4))]
            (unless (find |(= $ id) (os :windows)) (array/push (os :windows) id))
            (when (= 0 (math/rng-int rng 2)) (rt/dispatch r [:window-opened id])))   # often missed
        1 (let [id (ids (math/rng-int rng 4))]
            (put (os :rects) id (g/rect (math/rng-int rng 40) 0 10 10)))             # user drags, no event
        2 (rt/dispatch r [:command :next-layout])
        3 (rt/dispatch r [:command :focus-next])
        4 (rt/dispatch r [:window-moved (ids (math/rng-int rng 4)) (g/rect 1 2 3 4)])
        (rt/dispatch r [:command :swap-master])))
    # quiet: resync
    (rt/dispatch r [:windows-observed (map |[$ nil {:visible? true}] (os :windows))])
    (rt/dispatch r [:command :refresh])
    (eachp [id rect] (st/placements (rt/state r))
      (is= rect (get (os :rects) id)))
    # model windows == OS windows
    (is= (sort (array ;(os :windows)))
         (sort (array ;(mapcat |((((rt/state r) :workspaces) $) :ids) ["1" "2" "3"]))))))

(deftest "N1: a failed :goto is repaired by observing the real desktop"
  (def os (fake-os))
  (def r (make-rt os))
  (array/push (os :windows) :a)
  (rt/dispatch r [:window-opened :a])
  (put os :desktop "1")                   # the OS never left desktop 1
  (put (os :fail) :goto true)
  (rt/dispatch r [:command :goto "2"])
  (is= "2" ((rt/state r) :current))       # the core got ahead of the OS
  (run-later! os)
  (is= "1" ((rt/state r) :current)))
