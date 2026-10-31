(use ./t)
(import ../src/core/workspace :as w)

(defn build [& ids] (reduce w/insert (w/make "1") (reverse ids)))
# build :a :b :c => ids [:a :b :c], focus :a (last inserted = :a)

(deftest "insert with master focused (or empty) makes the new window master"
  (def x (w/insert (w/insert (w/make "1") :a) :b))
  (is= [:b :a] (x :ids))
  (is= :b (x :focus)))

(deftest "insert is idempotent"
  (def x (build :a :b))
  (is= x (w/insert x :a)))

(deftest "remove: unfocused window keeps focus"
  (is= :a ((w/remove (build :a :b :c) :c) :focus)))

(deftest "remove: focused window hands focus to the one now in its place"
  (def x (w/focus-id (build :a :b :c) :b))
  (def y (w/remove x :b))
  (is= [:a :c] (y :ids))
  (is= :c (y :focus)))

(deftest "remove: last window hands focus to the new last"
  (def y (w/remove (w/focus-id (build :a :b :c) :c) :c))
  (is= :b (y :focus)))

(deftest "remove: emptying the workspace clears focus; unknown id is a no-op"
  (is= nil ((w/remove (build :a) :a) :focus))
  (def x (build :a))
  (is= x (w/remove x :zzz)))

(deftest "focus-next / prev wrap"
  (def x (build :a :b :c))
  (is= :b ((w/focus-next x) :focus))
  (is= :c ((w/focus-prev x) :focus))
  (is= :a ((w/focus-next (w/focus-id x :c)) :focus)))

(deftest "focus ops on an empty workspace are no-ops"
  (def e (w/make "1"))
  (is= e (w/focus-next e))
  (is= e (w/swap-master e))
  (is= e (w/swap-next e)))

(deftest "swap-master trades places with master (xmonad swapMaster)"
  (def y (w/swap-master (w/focus-id (build :a :b :c :d) :c)))
  (is= [:c :b :a :d] (y :ids))
  (is= :c (y :focus)))

(deftest "swap-master is a no-op when master is focused"
  (def x (build :a :b))
  (is= x (w/swap-master x)))

(deftest "shift-master moves focused to the front, others keep order"
  (def y (w/shift-master (w/focus-id (build :a :b :c :d) :c)))
  (is= [:c :a :b :d] (y :ids))
  (is= :c (y :focus)))

(deftest "insert takes the focused position, old window moves down"
  (def x (w/focus-id (build :a :b :c) :b))
  (def y (w/insert x :n))
  (is= [:a :n :b :c] (y :ids))
  (is= :n (y :focus)))

(deftest "swap-next / prev exchange with neighbour"
  (def x (build :a :b :c))
  (is= [:b :a :c] ((w/swap-next x) :ids))
  (is= [:a :c :b] ((w/swap-prev (w/focus-id x :c)) :ids)))

(deftest "swap-next at the end rotates the window to the front (xmonad)"
  (def y (w/swap-next (w/focus-id (build :a :b :c) :c)))
  (is= [:c :a :b] (y :ids)))

(deftest "swap-prev at the front rotates the window to the end"
  (is= [:b :c :a] ((w/swap-prev (build :a :b :c)) :ids)))

(deftest "nmaster never goes below 0"
  (def x (w/make "1"))
  (is= 2 ((w/inc-master x) :nmaster))
  (is= 0 ((w/dec-master (w/dec-master x)) :nmaster)))

(deftest "ratio is clamped to [0.1, 0.9]"
  (def x (w/make "1"))
  (is= 0.9 ((w/resize-master x 5) :ratio))
  (is= 0.1 ((w/resize-master x -5) :ratio)))
