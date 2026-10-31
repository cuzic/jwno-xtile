# Enforces ADR 0001: src/core is pure. Two layers:
#  1. imports must be core-relative ("./...") -- allow-list, not deny-list
#  2. no symbol from an impure namespace, whether imported or built in
#     (os/, file/, ffi/, ev/, net/, math/rng, ...)
(use ./t)

(def forbidden-prefixes
  ["os/" "file/" "ffi/" "ev/" "net/" "thread/" "debug/" "gccollect"
   "math/rng" "math/random" "math/seedrandom"
   "slurp" "spit" "print" "eprint" "prin" "pp" "dyn" "setdyn" "root-env"
   "jw32" "jwno" "require" "eval" "compile" "run-context" "load-image"
   "native" "module/"])

(def sym-peg
  ~(any (+ (capture (some (+ (range "az" "AZ" "09")
                             (set "!$%&*+-./:<=>?@^_|~"))))
           1)))

(def import-peg
  ~(any (+ (* (+ "(import" "(use" "(require") (some (set " \t\r\n"))
              (capture (some (if-not (set " \t\r\n)") 1))))
           1)))

(defn strip-comments
  "Remove `#` comments, but not a `#` inside a string literal (so code after
  such a string is still checked)."
  [src]
  (def out @"")
  (var in-str false)
  (var in-comment false)
  (var i 0)
  (while (< i (length src))
    (def c (get src i))
    (cond
      in-comment (when (= c (chr "\n")) (set in-comment false) (buffer/push out c))
      in-str (do (buffer/push out c)
                 (cond (= c (chr "\\")) (do (++ i) (when (< i (length src)) (buffer/push out (get src i))))
                       (= c (chr "\"")) (set in-str false)))
      (= c (chr "#")) (set in-comment true)
      (= c (chr "\"")) (do (set in-str true) (buffer/push out c))
      (buffer/push out c))
    (++ i))
  (string out))

(def core-dir "src/core")

(defn core-files []
  (map |(string core-dir "/" $)
       (filter |(string/has-suffix? ".janet" $) (sort (os/dir core-dir)))))

(deftest "core imports are core-relative only"
  (each f (core-files)
    (def src (strip-comments (slurp f)))
    (each target (peg/match import-peg src)
      (when (or (not (string/has-prefix? "./" target)) (string/find ".." target))
        (errorf "%s imports %s (only ./ imports within core allowed)" f target)))))

(deftest "core uses no impure symbols"
  (each f (core-files)
    (def src (strip-comments (slurp f)))
    (each sym (peg/match sym-peg src)
      (each p forbidden-prefixes
        (when (or (= sym p) (string/has-prefix? (string p "/") sym)
                  (and (string/has-suffix? "/" p) (string/has-prefix? p sym)))
          (errorf "%s uses impure symbol %s" f sym))))))

(deftest "purity checker catches what it should (self-test)"
  (defn violations [src]
    (def stripped (strip-comments src))
    (def bad @[])
    (each target (peg/match import-peg stripped)
      (when (or (not (string/has-prefix? "./" target)) (string/find ".." target))
        (array/push bad target)))
    (each sym (peg/match sym-peg stripped)
      (each p forbidden-prefixes
        (when (or (= sym p) (string/has-prefix? (string p "/") sym)
                  (and (string/has-suffix? "/" p) (string/has-prefix? p sym)))
          (array/push bad sym))))
    bad)
  (is (not (empty? (violations "(import jw32/_winuser)"))))
  (is (not (empty? (violations "(defn f [] (os/time))"))))
  (is (not (empty? (violations "(file/open \"x\")"))))
  (is (not (empty? (violations "(math/rng 1)"))))
  (is (not (empty? (violations "(print 1)"))))
  (is (empty? (violations "(import ./geometry :as g) (g/rect 1 2 3 4)")))
  (is (empty? (violations "# (os/time) in a comment is fine\n(+ 1 2)")))
  # R12: leaving core through a ./ prefix, and code hiding after a "#" string
  (is (not (empty? (violations "(import ./../shell/x)"))))
  (is (not (empty? (violations "(def x \"#\") (os/time)"))))
  (is (empty? (violations "(def x \"# not a comment\") (+ 1 2)"))))
