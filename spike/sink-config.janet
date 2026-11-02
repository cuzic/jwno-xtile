# SPIKE for ADR 0006 D-7b (rev. 4d): a "sink" window made on Jwno's UI thread, to hold the OS focus when
# the visible workspace is empty. Everything here is a measurement; nothing is production code.
# The handler and the window procedure run in Jwno's UI thread (marshalled there), so they only use
# jw32 functions and constants, and write their observations to $SINK_OUT themselves.
# Run:  jwno.exe --config spike/sink-config.janet --repl 127.0.0.1:<port>      (spike/run-sink.ps1 does it)

(use jw32/_winuser)
(use jw32/_libloaderapi)
(use jw32/_errhandlingapi)
(use jw32/_util)               # null?, ...
(import jwno/util)

(def out-path (or (os/getenv "SINK_OUT") "sink.log"))

(defn rec [what & xs]
  (def f (file/open out-path :a))
  (when f
    (file/write f (string/format "%.3f %s %s\n" (os/clock :realtime) what
                                 (string/join (map |(string/format "%q" $) xs) " ")))
    (file/flush f)
    (file/close f)))

(rec :config-start)

# ---- runs in the UI thread ------------------------------------------------------------
(rec :step :start-defs)
(defn sink-wndproc [hwnd msg wparam lparam]
  (cond
    # keys: swallowed (returned 0), and counted so the script can see they arrived HERE
    (or (= msg WM_KEYDOWN) (= msg WM_KEYUP) (= msg WM_CHAR) (= msg WM_SYSKEYDOWN) (= msg WM_SYSKEYUP) (= msg WM_SYSCHAR))
    (do (rec :sink-key msg (int/to-number wparam)) 0)
    (= msg WM_CLOSE) (do (rec :sink-close-dropped) 0)
    (= msg WM_SYSCOMMAND)
    (if (= (band (int/to-number wparam) 0xFFF0) 0xF060)      # SC_CLOSE (Alt+F4)
      (do (rec :sink-sc-close-dropped) 0)
      (DefWindowProc hwnd msg wparam lparam))
    (= msg WM_DESTROY) (do (rec :sink-destroyed) (DefWindowProc hwnd msg wparam lparam))
    (DefWindowProc hwnd msg wparam lparam)))

(rec :step :wndproc-defined)

(defn create-sink [_hwnd _msg _wparam _lparam _hook state]
  (def wc (WNDCLASSEX :lpfnWndProc sink-wndproc
                      :hInstance (GetModuleHandle nil)
                      :lpszClassName "xtile-sink-spike"
                      :hCursor (LoadCursor nil IDC_ARROW)))
  (when (null? (RegisterClassEx wc))
    (rec :sink-class-failed (GetLastError)))
  (def h (CreateWindowEx WS_EX_TOOLWINDOW "xtile-sink-spike" "xtile: 空のワークスペース"
                         WS_POPUP -32000 -32000 1 1 nil nil (GetModuleHandle nil) nil))
  (if (null? h)
    (do (rec :sink-create-failed (GetLastError)) 0)
    (do
      (put state :xtile-sink h)
      (ShowWindow h SW_SHOWNOACTIVATE)
      (def n (util/pointer-to-number h))
      (rec :sink-created n)
      n)))

(rec :step :create-defined)

(defn front-sink [_hwnd _msg _wparam _lparam _hook state]
  (def h (in state :xtile-sink))
  (if (nil? h)
    (do (rec :sink-front-no-window) 0)
    (do
      (def ok (SetForegroundWindow h))
      (def fg (GetForegroundWindow))
      (rec :sink-front ok (= (util/pointer-to-number fg) (util/pointer-to-number h)))
      (if ok 1 0))))

(rec :step :front-defined)

(defn destroy-sink [_hwnd _msg _wparam _lparam _hook state]
  (when-let [h (in state :xtile-sink)]
    (DestroyWindow h)
    (put state :xtile-sink nil))
  0)

(rec :step :handlers-defined)
# ---- runs in the main thread ----------------------------------------------------------
(def ui-man (in jwno/context :ui-manager))
(rec :step :ui-man (type ui-man))
(def msgs @{})

(defn ui-call [name handler]
  (put msgs name (:add-custom-message ui-man handler))
  (rec :msg-registered name (msgs name)))

(defmacro guard [name & body] ~(try (do ,;body) ([e] (rec :error ,name (string e)))))
(guard :keymap
  (def key-man (in jwno/context :key-manager))
  (def keymap (:new-keymap key-man))
  (:add-command (in jwno/context :command-manager) :sink-hotkey (fn [] (rec :hotkey-fired)))
  (:define-key keymap "Alt+Shift+F11" :sink-hotkey)
  (:set-keymap key-man keymap))
(rec :step :keymap-done)

# which window Jwno says has the focus (what the adapter's focus-changed hook would see)
(guard :hook
  (:add-hook (in jwno/context :hook-manager) :focus-changed
             (fn [hwnd] (rec :jwno-focus-changed (util/pointer-to-number hwnd)))))
(rec :step :hook-done)

(ev/spawn
  (ev/sleep 1.0)
  (guard :register
    (ui-call :create create-sink)
    (ui-call :front front-sink)
    (ui-call :destroy destroy-sink))
  (rec :step :registered)
  # create on the UI thread; the script (run-sink.ps1) asks for the rest with the REPL
  (def n (try (:send-message ui-man (msgs :create) 0 0) ([e] (rec :create-error (string e)) nil)))
  (rec :create-result n))

# The script (run-sink.ps1) drives the rest with flag files next to the log (a REPL call hung in CI):
# front.flag -> make the sink the foreground window; destroy.flag -> destroy it.
(def flag-dir (let [i (last (string/find-all "\\" out-path))
                    j (last (string/find-all "/" out-path))
                    k (max (or i -1) (or j -1))]
                (if (>= k 0) (string/slice out-path 0 (+ k 1)) "")))
(defn flag? [name]
  (def path (string flag-dir name))
  (when (os/stat path)
    (os/rm path)
    true))
(ev/spawn
  (forever
    (ev/sleep 0.3)
    (when (flag? "front.flag")
      (rec :flag :front)
      (def r (try (:send-message ui-man (msgs :front) 0 0) ([e] (rec :front-error (string e)) nil)))
      (rec :front-result r))
    (when (flag? "destroy.flag")
      (rec :flag :destroy)
      (def r (try (:send-message ui-man (msgs :destroy) 0 0) ([e] (rec :destroy-error (string e)) nil)))
      (rec :destroy-result r))))
(rec :config-end)
