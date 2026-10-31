# Minimal test harness (no dependencies): (deftest name body...) registers,
# (run-all) executes. Failures are collected and reported together.

(var- tests @[])

(defn register [name f] (array/push tests [name f]))

(defmacro deftest [name & body]
  ~(,register ,name (fn [] ,;body)))

(defn run-all []
  (var failed 0)
  (each [name f] tests
    (def fib (fiber/new f :e))
    (def res (resume fib))
    (if (= :error (fiber/status fib))
      (do (++ failed)
          (eprintf "FAIL %s\n  %s" name (string res))
          (debug/stacktrace fib res ""))
      (printf "ok   %s" name)))
  (printf "\n%d tests, %d failed" (length tests) failed)
  (os/exit (if (zero? failed) 0 1)))

(defmacro is= [expected actual]
  (with-syms [e a]
    ~(let [,e ,expected ,a ,actual]
       (unless (deep= ,e ,a)
         (errorf "expected %q\n       got %q\n  in %q" ,e ,a ',actual)))))

(defmacro is [form]
  ~(unless ,form (errorf "assertion failed: %q" ',form)))
