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
