(use ./t)
(import ../src/core/geometry :as g)
(import ../src/core/layout :as l)

(def screen (g/rect 0 0 1000 600))
(def p {:nmaster 1 :ratio 0.5})

(defn rects [name params ids] (map |($ 1) (l/arrange name params screen ids)))

(deftest "tall: no windows"
  (is= [] (l/arrange :tall p screen [])))

(deftest "tall: one window fills the screen"
  (is= [[:a screen]] (l/arrange :tall p screen [:a])))

(deftest "tall: master left, stack right"
  (is= [[:a (g/rect 0 0 500 600)]
        [:b (g/rect 500 0 500 300)]
        [:c (g/rect 500 300 500 300)]]
       (l/arrange :tall p screen [:a :b :c])))

(deftest "tall: nmaster 2 stacks masters in the left column"
  (is= [[:a (g/rect 0 0 500 300)]
        [:b (g/rect 0 300 500 300)]
        [:c (g/rect 500 0 500 600)]]
       (l/arrange :tall {:nmaster 2 :ratio 0.5} screen [:a :b :c])))

(deftest "tall: nmaster >= n or 0 gives a single column"
  (def one-col [[:a (g/rect 0 0 1000 300)] [:b (g/rect 0 300 1000 300)]])
  (is= one-col (l/arrange :tall {:nmaster 2 :ratio 0.5} screen [:a :b]))
  (is= one-col (l/arrange :tall {:nmaster 0 :ratio 0.5} screen [:a :b])))

(deftest "tall: ratio sets master width"
  (is= 300 (((first (l/arrange :tall {:nmaster 1 :ratio 0.3} screen [:a :b])) 1) :w)))

(deftest "tall: honours screen offset"
  (def off (g/rect 100 50 1000 600))
  (is= [[:a (g/rect 100 50 500 600)] [:b (g/rect 600 50 500 600)]]
       (l/arrange :tall p off [:a :b])))

(deftest "wide: master on top, stack below"
  (is= [[:a (g/rect 0 0 1000 300)]
        [:b (g/rect 0 300 500 300)]
        [:c (g/rect 500 300 500 300)]]
       (l/arrange :wide p screen [:a :b :c])))

(deftest "full: every window gets the whole screen"
  (is= [[:a screen] [:b screen]] (l/arrange :full p screen [:a :b])))

(deftest "unknown layout is an error"
  (is (not (first (protect (l/arrange :nope p screen [:a]))))))

(deftest "remainder pixels go to the later windows, like xmonad's splitVertically"
  (def scr (g/rect 0 0 1000 601))
  (def hs (map |(($ 1) :h) (l/arrange :tall p scr [:a :b :c])))
  # stack column: 601 split in 2 -> 300, 301
  (is= [601 300 301] (tuple ;hs)))

# ---- ADR 0013: gaps and padding -----------------------------------------------------------------------------

(def sp-screen (g/rect 100 50 1000 600))

(deftest "G-1: gap = padding = 0 is exactly `arrange` (every layout, 0..12 windows)"
  (each name l/layouts
    (for n 0 13
      (def ids (map |(keyword "w" $) (range n)))
      (is= (l/arrange name {:nmaster 1 :ratio 0.5} sp-screen ids)
           (l/arrange-spaced name {:nmaster 1 :ratio 0.5} sp-screen ids 0 0)))))

(deftest "G-2/G-3: tiles stay inside the padded screen, never overlap, and neighbours are exactly `gap` apart"
  (each name [:tall :wide]
    (each gap [1 2 3 7 10]
      (each padding [0 5 12]
        (for n 1 11
          (each nmaster [1 2]
            (def ids (map |(keyword "w" $) (range n)))
            (def params {:nmaster nmaster :ratio 0.6})
            (def inner (if (pos? padding) (l/inset sp-screen padding) sp-screen))
            (def rs (map |($ 1) (l/arrange-spaced name params sp-screen ids gap padding)))
            (each r rs
              (is (and (>= (r :x) (inner :x)) (>= (r :y) (inner :y))
                       (<= (+ (r :x) (r :w)) (+ (inner :x) (inner :w)))
                       (<= (+ (r :y) (r :h)) (+ (inner :y) (inner :h)))
                       (pos? (r :w)) (pos? (r :h)))))
            (for i 0 (length rs)
              (for j (+ i 1) (length rs)
                (is (not (g/overlap? (rs i) (rs j))))))
            # a second tile directly beside/below another one is exactly `gap` away (the small ones are rounded)
            (for i 0 (length rs)
              (for j 0 (length rs)
                (def a (rs i)) (def b (rs j))
                (when (and (not= i j) (= (+ (a :y) (a :h) gap) (b :y)) (< (a :x) (+ (b :x) (b :w))) (< (b :x) (+ (a :x) (a :w))))
                  (is= gap (- (b :y) (+ (a :y) (a :h)))))))))))))

(deftest "F7 inverse: giving the shrunk edges back reproduces the xmonad layout of the padded screen"
  (each name [:tall :wide]
    (each gap [2 4 6 9]
      (for n 1 9
        (def ids (map |(keyword "w" $) (range n)))
        (def params {:nmaster 1 :ratio 0.5})
        (def inner (l/inset sp-screen 10))
        (def base (l/arrange name params inner ids))
        (def spaced (l/arrange-spaced name params sp-screen ids gap 10))
        (for i 0 n
          (def r (get-in base [i 1]))
          (def q (get-in spaced [i 1]))
          # undo: edges that are not on the boundary of `inner` were moved in by ceil/floor(gap/2)
          (def hi (div (+ gap 1) 2)) (def lo (div gap 2))
          (def left? (not= (r :x) (inner :x))) (def top? (not= (r :y) (inner :y)))
          (def right? (not= (+ (r :x) (r :w)) (+ (inner :x) (inner :w))))
          (def bottom? (not= (+ (r :y) (r :h)) (+ (inner :y) (inner :h))))
          (is= r (g/rect (- (q :x) (if left? hi 0)) (- (q :y) (if top? hi 0))
                         (+ (q :w) (if left? hi 0) (if right? lo 0))
                         (+ (q :h) (if top? hi 0) (if bottom? lo 0)))))))))

(deftest "Full has no gap (the tiles overlap by design); a single window has none either; tiny rects keep 1 pixel"
  (def ids [:a :b :c])
  (is= (l/arrange :full {} sp-screen ids)
       (l/arrange-spaced :full {} sp-screen ids 8 0))
  (is= (l/arrange :tall {:nmaster 1 :ratio 0.5} sp-screen [:a])
       (l/arrange-spaced :tall {:nmaster 1 :ratio 0.5} sp-screen [:a] 8 0))
  (def tiny (l/arrange-spaced :tall {:nmaster 1 :ratio 0.5} (g/rect 0 0 6 6) [:a :b :c :d] 20 0))
  (each [_ r] tiny (is (and (pos? (r :w)) (pos? (r :h))))))
