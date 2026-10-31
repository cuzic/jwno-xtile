# Jwno config for the CONTRACT tests of the xtile adapter (ADR 0010 stage 2).
# Loads the real adapter into real Jwno, and writes (a) every event of interest and (b) a JSON
# snapshot of the core's state once a second to $CONTRACT_OUT, for spike/run-contract.ps1 to judge.
# Run:  jwno.exe --mod-path <repo> --config spike/contract-config.janet --repl 127.0.0.1:9999

(def out-path (or (os/getenv "CONTRACT_OUT") "contract.log"))
(def out (file/open out-path :a))

(defn rec [what & xs]
  (file/write out (string/format "%.3f %s %s\n" (os/clock :realtime) what
                                 (string/join (map |(string/format "%q" $) xs) " ")))
  (file/flush out))

(defn xlog [level msg] (rec :xtile-log level msg))

(rec :config-start)

# Import failures must not pop up a dialog and hang the job: record them instead.
(defn try-require [path]
  (try (require path)
    ([e] (rec :import-error path (string e)) nil)))

(def adapter-env (try-require "src/jwno/adapter"))
(def w32-env (try-require "src/jwno/win32"))
(def runtime-env (try-require "src/shell/runtime"))
(def state-env (try-require "src/core/state"))
(def keymap-env (try-require "src/core/keymap"))

(defn sym [env name] (when env (get-in env [(symbol name) :value])))

(def install (sym adapter-env "install"))
(def win32 (sym w32-env "win32"))
(def get-state (sym runtime-env "state"))
(def placements (sym state-env "placements"))
(def default-bindings (sym keymap-env "default-bindings"))
(def default-tags (sym adapter-env "default-tags"))

(rec :modules-loaded (not (nil? install)) (not (nil? win32)) (not (nil? get-state)))

# Count every focus Jwno or the adapter really performs (the leaf of all focus paths).
# This wrapper goes in BEFORE the adapter's, so the adapter's suppression sits above it.
(let [wm (in jwno/context :window-manager)
      orig (in wm :set-focus-to-hwnd)]
  (put wm :set-focus-to-hwnd
       (fn [self & args]
         (rec :leaf-set-focus-to-hwnd ;args)
         (orig self ;args))))

(def key-man (in jwno/context :key-manager))
(def keymap (:new-keymap key-man))

(var xtile nil)
(when (and install win32)
  (try
    (set xtile
         (install jwno/context win32
                  {:log xlog
                   :keymap keymap
                   :bindings (default-bindings "Alt" default-tags)
                   :poll-seconds 2}))
    ([e f]
     (rec :install-error (string e))
     (debug/stacktrace f e ""))))

(:set-keymap key-man keymap)

(when xtile
  (rec :installed :a-active (xtile :a-active?))
  (try ((xtile :start)) ([e] (rec :start-error (string e))))
  (rec :started))

# ---- a JSON snapshot of the core's state, once a second ----
(defn jstr [x] (string/format "%j" (string x)))
(defn jnum-or-null [x] (if (number? x) (string x) "null"))

(defn dump-state []
  (when (and xtile get-state)
    (def s (get-state (xtile :rt)))
    (def p (placements s))
    (def wins @[])
    (each tag (s :tags)
      (def w (get-in s [:workspaces tag]))
      (each id (w :ids)
        (def r (get p id))
        (array/push wins
                    (string/format "{\"id\":%d,\"tag\":%s,\"floating\":%s,\"rect\":%s}"
                                   id (jstr tag)
                                   (if (get-in s [:floating id]) "true" "false")
                                   (if r (string/format "[%d,%d,%d,%d]" (r :x) (r :y) (r :w) (r :h)) "null")))))
    (file/write out
                (string/format "%.3f STATE {\"current\":%s,\"os_focus\":%s,\"external\":%s,\"windows\":[%s]}\n"
                               (os/clock :realtime) (jstr (s :current))
                               (jnum-or-null (s :os-focus))
                               (if (s :external-focus) "true" "false")
                               (string/join wins ",")))
    (file/flush out)))

(ev/spawn
  (forever
    (ev/sleep 1)
    (try (dump-state) ([e] (rec :dump-error (string e))))))
