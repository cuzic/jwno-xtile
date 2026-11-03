# One workspace = ordered window ids (master first) + focus + layout params.
# Immutable: every function returns a new workspace.

(import ./data :as d)

(defn make [tag]
  {:tag tag :ids [] :focus nil :layout :tall :nmaster 1 :ratio 0.5})

(defn- set-focus
  "Janet structs cannot hold nil, so `no focus` means the key is absent
  (`merge` with {:focus nil} would silently keep the old value)."
  [ws id]
  (def t (table ;(kvs ws)))
  (put t :focus id)
  (table/to-struct t))

(defn- index-of [ws id] (find-index |(= $ id) (ws :ids)))

(defn has? [ws id] (not (nil? (index-of ws id))))

(defn- with-ids [ws ids &opt focus]
  (d/assoc ws {:ids (tuple ;ids) :focus (or focus (ws :focus))}))

(defn insert
  "xmonad's insertUp: the new window takes the focused window's position
  (the old one moves one step down) and gets focus. It is master only when
  master was focused or the workspace was empty."
  [ws id]
  (if (has? ws id)
    ws
    (let [i (or (and (ws :focus) (index-of ws (ws :focus))) 0)
          ids (ws :ids)]
      (d/assoc ws {:ids [;(slice ids 0 i) id ;(slice ids i)] :focus id}))))

(defn append
  "Add at the end without touching focus (an *observed* window must not steal
  it). Only an empty workspace takes the window as its focus (invariant I2)."
  [ws id]
  (cond
    (has? ws id) ws
    (empty? (ws :ids)) (d/assoc ws {:ids [id] :focus id})
    (d/assoc ws {:ids [;(ws :ids) id]})))

(defn remove
  "Focus falls to the window now at the same position, else the last one."
  [ws id]
  (if-let [i (index-of ws id)]
    (let [ids (tuple ;(array/remove (array ;(ws :ids)) i))
          focus (cond
                  (not= id (ws :focus)) (ws :focus)
                  (empty? ids) nil
                  (ids (min i (- (length ids) 1))))]
      (set-focus (d/assoc ws {:ids ids}) focus))
    ws))

(defn focus-id [ws id] (if (has? ws id) (d/assoc ws {:focus id}) ws))

(defn- focus-offset [ws d]
  (def n (length (ws :ids)))
  (if (zero? n)
    ws
    (let [i (or (index-of ws (ws :focus)) 0)]
      (d/assoc ws {:focus ((ws :ids) (mod (+ i d) n))}))))

(defn focus-next [ws] (focus-offset ws 1))
(defn focus-prev [ws] (focus-offset ws -1))

(defn focus-master [ws]
  (if (empty? (ws :ids)) ws (d/assoc ws {:focus ((ws :ids) 0)})))

(defn swap-master
  "xmonad's swapMaster: master and the focused window trade places; focus
  stays with the moved window."
  [ws]
  (def i (and (ws :focus) (index-of ws (ws :focus))))
  (if (or (nil? i) (zero? i))
    ws
    (let [ids (array ;(ws :ids))]
      (put ids i (ids 0))
      (put ids 0 (ws :focus))
      (d/assoc ws {:ids (tuple ;ids)}))))

(defn shift-master
  "xmonad's shiftMaster: focused window goes to the front, the others keep
  their order."
  [ws]
  (if-let [f (ws :focus)
           i (index-of ws f)]
    (d/assoc ws {:ids [f ;(filter |(not= $ f) (ws :ids))]})
    ws))

(defn- swap-offset [ws d]
  (def n (length (ws :ids)))
  (def i (and (ws :focus) (index-of ws (ws :focus))))
  (cond
    (or (nil? i) (< n 2)) ws
    # wrap like xmonad: moving past the end rotates the focused window around
    (and (= d 1) (= i (- n 1)))
    (with-ids ws [(ws :focus) ;(slice (ws :ids) 0 (- n 1))])
    (and (= d -1) (= i 0))
    (with-ids ws [;(slice (ws :ids) 1) (ws :focus)])
    (let [ids (array ;(ws :ids))
          j (+ i d)]
      (put ids i (ids j))
      (put ids j (ws :focus))
      (with-ids ws ids))))

(defn swap-next [ws] (swap-offset ws 1))
(defn swap-prev [ws] (swap-offset ws -1))

(defn inc-master [ws] (d/assoc ws {:nmaster (+ (ws :nmaster) 1)}))
(defn dec-master [ws] (d/assoc ws {:nmaster (max 0 (- (ws :nmaster) 1))}))

(defn resize-master [ws delta]
  (d/assoc ws {:ratio (max 0.1 (min 0.9 (+ (ws :ratio) delta)))}))

(defn set-layout [ws name] (d/assoc ws {:layout name}))
