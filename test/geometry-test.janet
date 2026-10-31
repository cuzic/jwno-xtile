(use ./t)
(import ../src/core/geometry :as g)

(deftest "divide-evenly sums to len and pushes the remainder to the later parts (xmonad)"
  (is= [3 3 4] (g/divide-evenly 10 3))
  (is= [5] (g/divide-evenly 5 1))
  (is= [0 1 1] (g/divide-evenly 2 3)))

(deftest "split-len clamps so both sides stay non-empty"
  (is= 5 (g/split-len 10 0.5))
  (is= 1 (g/split-len 10 0.0))
  (is= 9 (g/split-len 10 1.0))
  (is= 1 (g/split-len 1 0.5)))

(deftest "stack-vertically tiles exactly"
  (def bands (g/stack-vertically (g/rect 10 20 100 31) 3))
  (is= [20 30 40] (tuple ;(map |($ :y) bands)))
  (is= 31 (sum (map |($ :h) bands))))

(deftest "transpose is an involution"
  (def r (g/rect 1 2 3 4))
  (is= r (g/transpose (g/transpose r)))
  (is= (g/rect 2 1 4 3) (g/transpose r)))

(deftest "overlap?"
  (is (g/overlap? (g/rect 0 0 10 10) (g/rect 5 5 10 10)))
  (is (not (g/overlap? (g/rect 0 0 10 10) (g/rect 10 0 10 10))))
  (is (not (g/overlap? (g/rect 0 0 10 10) (g/rect 0 10 10 10)))))
