# OS calls for src/jwno/adapter.janet, through jw32 (ADR 0010 D1). THE ONLY FILE THAT IMPORTS jw32.
# It can be loaded only inside Jwno on Windows. Every jw32 name below was read from Jwno 0.9.16's own
# source where Jwno uses it (GetAncestor, GetWindow, GetWindowLong, IsIconic, IsWindowVisible,
# GetForegroundWindow, GetWindowRect, MonitorFromWindow, GetMonitorInfo, CoCreateInstance); the rest
# (IsHungAppWindow, MessageBeep) are NOT in this jw32 (contract test CT-1 listed it); they are looked up by name at run time (a bare unknown symbol is a COMPILE error) and the adapter lives without them.
# UNVERIFIED ON WINDOWS: no test loads this file yet (ADR 0010 stage 2).

(use jw32/_winuser)
(use jw32/_combaseapi)
(use jw32/_shobjidl_core)
(use jw32/_util)
(import jwno/util)

(def- ws-caption 0x00C00000)
(def- ws-ex-toolwindow 0x00000080)

(defn- num [x] (if (number? x) x (int/to-number x)))

(defn- true? [x] (not= FALSE x))

(defn- opt
  "A jw32/Jwno function looked up by NAME at run time. Janet rejects an unknown symbol at compile
  time, so a function this jw32 build does not have must not be written as a bare symbol."
  [name]
  (get-in (curenv) [(symbol name) :value]))

(defn- guarded
  "Run f; if jw32 lacks the function or the call throws, return `fallback`."
  [fallback f]
  (def [ok v] (protect (f)))
  (if ok v fallback))

(defn- format-guid
  "16 raw bytes of a Windows GUID (Data1..3 little-endian) -> \"{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}\"
  in the same shape Jwno prints, so ids compare equal."
  [b]
  (def order [3 2 1 0 -1 5 4 -1 7 6 -1 8 9 -1 10 11 12 13 14 15])
  (def out @"{")
  (each i order
    (if (= i -1)
      (buffer/push-string out "-")
      (buffer/push-string out (string/format "%02X" (in b i)))))
  (buffer/push-string out "}")
  (string out))

(var- vdm nil)
(defn- vdm* []
  (or vdm
      (set vdm (CoCreateInstance CLSID_VirtualDesktopManager nil CLSCTX_INPROC_SERVER
                                 IVirtualDesktopManager))))

(defn foreground-hwnd [] (GetForegroundWindow))

(defn root-of [hwnd] (GetAncestor hwnd GA_ROOT))

(defn hwnd->number [hwnd] (util/pointer-to-number hwnd))

(defn minimized? [hwnd] (true? (IsIconic hwnd)))

(defn hung? [hwnd]
  (def f (opt "IsHungAppWindow"))
  (if f (guarded false (fn [] (true? (f hwnd)))) false))

(defn beep []
  (def f (opt "MessageBeep"))
  (when f (guarded nil (fn [] (f 0)))))

(defn desktop-guid
  "Synchronous and without Jwno's retry loop (which can block for ~1.5s). nil for windows that
  virtual desktops do not manage."
  [hwnd]
  (guarded nil
           (fn []
             (def did (:GetWindowDesktopId (vdm*) (GetAncestor hwnd GA_ROOT)))
             (when did (format-guid did)))))

(defn- fullscreen? [hwnd style]
  # the app asked for it: no caption AND the window covers its whole monitor. (A window WE tiled to
  # the full work area still has its caption, so it is not mistaken for a fullscreen request.)
  (and (zero? (band style ws-caption))
       (guarded false
                (fn []
                  (def [ret rect] (GetWindowRect hwnd))
                  (def mon (MonitorFromWindow hwnd MONITOR_DEFAULTTONEAREST))
                  (def info (MONITORINFOEX))
                  (and (true? ret) (true? (GetMonitorInfo mon info))
                       (let [m (in info :rcMonitor)]
                         (and (= (in rect :left) (in m :left)) (= (in rect :top) (in m :top))
                              (= (in rect :right) (in m :right)) (= (in rect :bottom) (in m :bottom)))))))))

(defn facts
  "classify's facts (ADR 0008). Win32 only -- no UIA, because the poll calls this for every window."
  [hwnd]
  (def style (signed-to-unsigned-32 (GetWindowLong hwnd GWL_STYLE)))
  (def ex-style (signed-to-unsigned-32 (GetWindowLong hwnd GWL_EXSTYLE)))
  # :class and :title are NOT here: this jw32 has no GetClassName/GetWindowText (contract test CT-1).
  # The adapter reads them from the UIA element in the :window-created hook.
  {:exe (guarded nil (fn [] (util/get-hwnd-path hwnd)))
   :visible? (true? (IsWindowVisible hwnd))
   :minimized? (minimized? hwnd)
   :fullscreen? (fullscreen? hwnd (num style))
   :tool-window? (not (zero? (band (num ex-style) ws-ex-toolwindow)))
   :owned? (not (nil? (GetWindow hwnd GW_OWNER)))})

(def win32
  {:foreground-hwnd foreground-hwnd
   :root-of root-of
   :hwnd->number hwnd->number
   :facts facts
   :desktop-guid desktop-guid
   :minimized? minimized?
   :hung? hung?
   :beep beep
   :swp-nomove-nosize (bor SWP_NOMOVE SWP_NOSIZE)})
