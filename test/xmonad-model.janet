# Independent reference model of xmonad's Stack zipper, transcribed from
# xmonad/src/XMonad/StackSet.hs (insertUp, delete', focusUp', focusDown',
# swapUp', swapDown, swapMaster, shiftMaster, focusMaster).
#
# Stack = {:focus t :up [nearest-first ...] :down [...]}  or nil when empty.
# Deliberately written in a different shape from src/core/workspace.janet
# (zipper vs. index list) so the two cannot share the same mistake.

(defn stack [t up down] {:focus t :up up :down down})

(defn to-ids [s] (if s [;(reverse (s :up)) (s :focus) ;(s :down)] []))
(defn focus-of [s] (and s (s :focus)))

(defn- rev [s] (stack (s :focus) (s :down) (s :up)))

(defn member? [s a] (not (nil? (find |(= $ a) (to-ids s)))))

(defn insert-up [s a]
  (cond
    (member? s a) s
    (nil? s) (stack a [] [])
    (stack a (s :up) [(s :focus) ;(s :down)])))

(defn focus-up [s]
  (cond
    (nil? s) s
    (not (empty? (s :up)))
    (stack (first (s :up)) (slice (s :up) 1) [(s :focus) ;(s :down)])
    (let [r (reverse [(s :focus) ;(s :down)])]
      (stack (first r) (slice r 1) []))))

(defn focus-down [s] (and s (rev (focus-up (rev s)))))

(defn swap-up [s]
  (cond
    (nil? s) s
    (not (empty? (s :up)))
    (stack (s :focus) (slice (s :up) 1) [(first (s :up)) ;(s :down)])
    (stack (s :focus) (reverse (s :down)) [])))

(defn swap-down [s] (and s (rev (swap-up (rev s)))))

(defn swap-master [s]
  (cond
    (or (nil? s) (empty? (s :up))) s
    (let [r (reverse (s :up))] # master first
      (stack (s :focus) []
             [;(slice r 1) (first r) ;(s :down)]))))

(defn shift-master [s]
  (cond
    (or (nil? s) (empty? (s :up))) s
    (stack (s :focus) [] [;(reverse (s :up)) ;(s :down)])))

(defn focus-master [s]
  (cond
    (or (nil? s) (empty? (s :up))) s
    (let [r (reverse (s :up))]
      (stack (first r) [] [;(slice r 1) (s :focus) ;(s :down)]))))

(defn delete [s a]
  (cond
    (not (member? s a)) s
    (not= (s :focus) a)
    (stack (s :focus)
           (filter |(not= $ a) (s :up))
           (filter |(not= $ a) (s :down)))
    # focused: prefer the window below, else the one above
    (not (empty? (s :down)))
    (stack (first (s :down)) (s :up) (slice (s :down) 1))
    (not (empty? (s :up)))
    (stack (first (s :up)) (slice (s :up) 1) [])
    nil))

(defn focus-id
  "Move focus to `a` keeping order (xmonad's focusWindow within a stack)."
  [s a]
  (if (member? s a)
    (let [ids (to-ids s)
          i (find-index |(= $ a) ids)]
      (stack a (reverse (slice ids 0 i)) (slice ids (+ i 1))))
    s))
