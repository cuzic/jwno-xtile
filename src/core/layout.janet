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

# ---- ADR 0013: gaps and padding, a post-processing that never touches the xmonad-exact `arrange` ----

(defn inset
  "`screen` shrunk by `n` on all four sides; never below 1x1 (the inset is reduced when the screen is too small)."
  [screen n]
  (def dx (min n (div (- (screen :w) 1) 2)))
  (def dy (min n (div (- (screen :h) 1) 2)))
  (g/rect (+ (screen :x) dx) (+ (screen :y) dy) (- (screen :w) (* 2 dx)) (- (screen :h) (* 2 dy))))

(defn- shrink-edges
  "One rect inside `inner`: an edge that is not on the boundary of `inner` moves in by ceil(gap/2) (left, top) or
  floor(gap/2) (right, bottom), so two neighbours are exactly `gap` apart. Never below 1x1."
  [r inner gap]
  (def hi (div (+ gap 1) 2))                   # ceil(gap/2)
  (def lo (div gap 2))                          # floor(gap/2)
  (def left? (not= (r :x) (inner :x)))
  (def top? (not= (r :y) (inner :y)))
  (def right? (not= (+ (r :x) (r :w)) (+ (inner :x) (inner :w))))
  (def bottom? (not= (+ (r :y) (r :h)) (+ (inner :y) (inner :h))))
  (var dl (if left? hi 0))
  (var dr (if right? lo 0))
  (var dt (if top? hi 0))
  (var db (if bottom? lo 0))
  # keep at least one pixel: take back from the larger side first
  (while (and (> (+ dl dr) (- (r :w) 1)) (> (+ dl dr) 0))
    (if (>= dl dr) (-= dl 1) (-= dr 1)))
  (while (and (> (+ dt db) (- (r :h) 1)) (> (+ dt db) 0))
    (if (>= dt db) (-= dt 1) (-= db 1)))
  (g/rect (+ (r :x) dl) (+ (r :y) dt) (- (r :w) dl dr) (- (r :h) dt db)))

(defn arrange-spaced
  "(arrange ...) with `padding` around the screen and `gap` between tiles. gap = padding = 0 is exactly `arrange`."
  [name params screen ids gap padding]
  (def inner (if (pos? padding) (inset screen padding) screen))
  (def placed (arrange name params inner ids))
  (if (or (zero? gap) (= name :full))
    placed
    (tuple ;(map (fn [[id r]] [id (shrink-edges r inner gap)]) placed))))
