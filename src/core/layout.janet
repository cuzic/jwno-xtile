# Pure layout functions: (arrange name params screen ids) -> [[id rect] ...]
# `ids` is in stack order, master first. params: {:nmaster int :ratio float}

(import ./geometry :as g)

(defn- tall
  [{:nmaster nmaster :ratio ratio} screen ids]
  (def n (length ids))
  (cond
    (zero? n) []
    # xmonad: everything in one column when nmaster covers all, or is 0
    (or (<= n nmaster) (zero? nmaster))
    (tuple ;(map |[$0 $1] ids (g/stack-vertically screen n)))
    (let [mw (g/split-len (screen :w) ratio)
          master-r (g/rect (screen :x) (screen :y) mw (screen :h))
          stack-r (g/rect (+ (screen :x) mw) (screen :y)
                          (- (screen :w) mw) (screen :h))
          masters (g/stack-vertically master-r nmaster)
          stack (g/stack-vertically stack-r (- n nmaster))]
      (tuple ;(map |[$0 $1] ids [;masters ;stack])))))

(defn- wide
  [params screen ids]
  (tuple ;(map (fn [[id r]] [id (g/transpose r)])
               (tall params (g/transpose screen) ids))))

(defn- full
  [_ screen ids]
  (tuple ;(map |[$ screen] ids)))

(def layouts
  "Cycle order for :next-layout."
  [:tall :wide :full])

(def- table-of {:tall tall :wide wide :full full})

(defn arrange [name params screen ids]
  ((assert (table-of name) (string "unknown layout " name)) params screen ids))
