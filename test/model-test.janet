# Differential test: src/core/workspace vs. the xmonad reference model.
(use ./t)
(import ../src/core/workspace :as w)
(import ./xmonad-model :as x)

(def ops
  # name, core-fn, model-fn, takes-an-id?
  [[:focus-next w/focus-next x/focus-down false]
   [:focus-prev w/focus-prev x/focus-up false]
   [:focus-master w/focus-master x/focus-master false]
   [:swap-next w/swap-next x/swap-down false]
   [:swap-prev w/swap-prev x/swap-up false]
   [:swap-master w/swap-master x/swap-master false]
   [:shift-master w/shift-master x/shift-master false]
   [:insert w/insert x/insert-up true]
   [:remove w/remove x/delete true]
   [:focus-id w/focus-id x/focus-id true]])

(defn same? [core model]
  (and (deep= (tuple ;(core :ids)) (tuple ;(x/to-ids model)))
       (= (core :focus) (x/focus-of model))))

(deftest "workspace ops agree with the xmonad reference model"
  (for seed 0 300
    (def rng (math/rng seed))
    (var core (w/make "1"))
    (var model nil)
    (def trace @[])
    (for _ 0 80
      (def [name cf mf takes-id?] (ops (math/rng-int rng (length ops))))
      (def id (keyword "w" (math/rng-int rng 8)))
      (array/push trace [name (if takes-id? id)])
      (set core (if takes-id? (cf core id) (cf core)))
      (set model (if takes-id? (mf model id) (mf model)))
      (unless (same? core model)
        (errorf "diverged (seed %d) after %q\n core:  %q focus %q\n model: %q focus %q"
                seed (last trace) (core :ids) (core :focus)
                (x/to-ids model) (x/focus-of model))))))
