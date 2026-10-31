# Pure integer rectangle arithmetic. Rects are structs {:x :y :w :h}.

(defn rect [x y w h] {:x x :y y :w w :h h})

(defn divide-evenly
  "Split `len` into `n` integer sizes summing to exactly `len`, the way
  xmonad's splitVertically does: each part is floor(remaining / parts left),
  so any remainder ends up in the later parts."
  [len n]
  (assert (pos? n) "divide-evenly: n must be positive")
  (var rem len)
  (tuple/slice
    (seq [i :range [0 n]]
      (def part (div rem (- n i)))
      (-= rem part)
      part)))

(defn split-len
  "First part of `len` for a ratio, clamped so both parts stay >= 1 when
  len >= 2."
  [len ratio]
  (if (< len 2)
    len
    (max 1 (min (- len 1) (math/floor (* len ratio))))))

(defn stack-vertically
  "Cut `r` into `n` horizontal bands, top to bottom."
  [r n]
  (var y (r :y))
  (tuple/slice
    (seq [h :in (divide-evenly (r :h) n)]
      (def band (rect (r :x) y (r :w) h))
      (+= y h)
      band)))

(defn transpose
  "Swap the axes of a rect (used to derive Wide from Tall)."
  [r]
  (rect (r :y) (r :x) (r :h) (r :w)))

(defn area [r] (* (r :w) (r :h)))

(defn overlap?
  [a b]
  (and (< (a :x) (+ (b :x) (b :w))) (< (b :x) (+ (a :x) (a :w)))
       (< (a :y) (+ (b :y) (b :h))) (< (b :y) (+ (a :y) (a :h)))))
