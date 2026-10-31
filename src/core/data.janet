# Immutable-update helper. Janet's `merge` returns a mutable table even for
# two structs, which silently breaks "state is immutable data" (and makes `=`
# compare by identity). Always use `assoc` instead.

(defn assoc
  "New struct: `m` with the key/value pairs of struct `kvs` laid over it."
  [m kvs]
  (table/to-struct (merge m kvs)))

(defn without
  "New struct: `m` minus `key` (structs cannot hold nil)."
  [m key]
  (def t (table ;(kvs m)))
  (put t key nil)
  (table/to-struct t))
