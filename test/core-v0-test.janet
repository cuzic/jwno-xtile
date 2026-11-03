# ADR 0012 M-4 (stage 1a): with a single monitor the core behaves EXACTLY as before the multi-monitor work.
# `test/reference/core-v0/` is a frozen copy of src/core/ taken before the accessor refactor (the core is pure and
# imports only ./ files, so the copy loads as is). Random event sequences are fed to both; every :state and :effects
# must be equal. When the representation changes (stage 1b) the comparison projects the state through the accessors.
(use ./t)
(import ../src/core/state :as st)
(import ../src/core/update :as u)
(import ./reference/core-v0/state :as st0)
(import ./reference/core-v0/update :as u0)
(import ./property-test :as pt)

(defn- project-old [s] s)   # the frozen core keeps :current and :screen as plain keys

(defn- project
  "A NEW state as the old core would have it: the keys the old core had, current/screen read through the accessors."
  [s]
  (def cur (st/current s))
  (def scr (st/screen s))
  (def t (table ;(kvs s)))
  (put t :screens nil)
  (put t :focused-screen nil)
  (put t :current cur)
  (put t :screen scr)
  (table/to-struct t))

(deftest "M-4: the new core and the frozen v0 core agree on every event of random sequences (single monitor)"
  (for seed 0 120
    (def rng (math/rng (+ 90000 seed)))
    (def rules (pt/random-rules rng))
    (def mode (if (zero? (math/rng-int rng 4)) :follow nil))       # :follow states too (R12i-M2)
    (var a (st/make (first pt/screens) pt/tags rules mode))
    (var b (st0/make (first pt/screens) pt/tags rules mode))
    (for step 0 120
      # :view is new in ADR 0012: the frozen v0 core does not know it (it would ignore it)
      (def e (let [e (pt/random-event rng)] (if (= (get e 1) :view) [:command :goto (get e 2)] e)))
      (def ra (u/update a e))
      (def rb (u0/update b e))
      (unless (deep= (project (ra :state)) (project-old (rb :state)))
        (errorf "M-4 state differs after %q (seed %d step %d)" e seed step))
      (unless (deep= (ra :effects) (rb :effects))
        (errorf "M-4 effects differ after %q: new=%q old=%q (seed %d step %d)" e (ra :effects) (rb :effects) seed step))
      (set a (ra :state))
      (set b (rb :state)))))
