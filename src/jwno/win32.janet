# OS calls for src/jwno/adapter.janet, through jw32 (ADR 0010 D1). THE ONLY FILE THAT IMPORTS jw32.
# It can be loaded only inside Jwno on Windows. Every jw32 name below was read from Jwno 0.9.16's own
# source where Jwno uses it (GetAncestor, GetWindow, GetWindowLong, IsIconic, IsWindowVisible,
# GetForegroundWindow, GetWindowRect, MonitorFromWindow, GetMonitorInfo, CoCreateInstance); the rest
# (IsHungAppWindow, MessageBeep) are NOT in this jw32 (contract test CT-1 listed it); they are looked up by name at run time (a bare unknown symbol is a COMPILE error) and the adapter lives without them.
# Loaded by the contract tests on hosted Windows Server 2022/2025 and on one real Windows 11 PC; see
# docs/spike/2026-11-01-real-machine.md for what is not covered.

(use jw32/_winuser)
(use jw32/_combaseapi)
(use jw32/_shobjidl_core)
(use jw32/_util)
(import jwno/util)

(def- ws-caption 0x00C00000)
(def- ws-ex-toolwindow 0x00000080)

(defn- num [x] (if (number? x) x (int/to-number x)))

(defn- bits-32
  "The 32 style bits as a signed 32-bit number. Janet's `band` takes 32-bit SIGNED integers only: a
  WS_POPUP style (bit 31) as an unsigned 2496135621 makes `band` throw 'out of range for 32-bit signed
  integers' (contract test CT-16 found this). Two's complement keeps `band` with small masks correct."
  [x]
  (def v (mod (num x) 4294967296))
  (if (>= v 2147483648) (- v 4294967296) v))

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

(defn on-current-desktop?
  "Windows' own answer (IVirtualDesktopManager, synchronous, no retry). Jwno's `last-vd` cannot be
  compared with a window's desktop id: at start it holds something else (contract test CT-3). If the
  question cannot be answered, the window counts as ours."
  [hwnd]
  (guarded true (fn [] (not= FALSE (:IsWindowOnCurrentVirtualDesktop (vdm*) (GetAncestor hwnd GA_ROOT))))))

(defn foreground-hwnd [] (GetForegroundWindow))

(defn root-of [hwnd] (GetAncestor hwnd GA_ROOT))

(defn hwnd->number [hwnd] (util/pointer-to-number hwnd))

(defn minimized? [hwnd] (true? (IsIconic hwnd)))

(defn zoomed? [hwnd] (true? (IsZoomed hwnd)))

(defn mouse-down?
  "Any mouse button is down (the left and right buttons are both checked, so a swapped-button setup is covered)."
  []
  (guarded false
           (fn []
             (or (neg? (num (GetAsyncKeyState 0x01)))     # VK_LBUTTON; the high bit of the SHORT = down
                 (neg? (num (GetAsyncKeyState 0x02)))))))

(defn watch-moves
  "Call (on-hwnd hwnd) when a window's move/resize loop ends (EVENT_SYSTEM_MOVESIZEEND). The
  callback runs INSIDE `pump`, on this thread, nested in a C call: it must not yield (ADR 0010 D9).
  Returns the hook handle, or nil if it could not be installed."
  [on-hwnd]
  (def hook
    (SetWinEventHook EVENT_SYSTEM_MOVESIZEEND EVENT_SYSTEM_MOVESIZEEND nil
                     (fn [_hook _event hwnd id-object _id-child _thread _time]
                       (when (= id-object OBJID_WINDOW) (on-hwnd hwnd)))
                     0 0 (bor WINEVENT_OUTOFCONTEXT WINEVENT_SKIPOWNPROCESS)))
  (when (and hook (not (null? hook))) hook))

(defn unwatch-moves [hook] (UnhookWinEvent hook))

(defn pump
  "WINEVENT_OUTOFCONTEXT callbacks are delivered only while the hooking thread pumps messages, and
  Jwno's main thread runs Janet's event loop, not a Win32 one. -> number of messages dispatched."
  []
  (def msg (MSG))
  (var n 0)
  (while (true? (PeekMessage msg nil 0 0 PM_REMOVE))
    (TranslateMessage msg)
    (DispatchMessage msg)
    (++ n))
  n)

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
             # Jwno's own COM wrapper hands this back as an already formatted "{...}" string (it compares
             # it to "{00000000-...}" in win.janet); formatting it again scrambled every id (contract test
             # CT-12/14). Only a raw 16-byte buffer needs formatting.
             (cond
               (nil? did) nil
               (string? did) (string/ascii-upper did)
               (format-guid did)))))

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

(defn- window-long
  "The style bits, or nil if they cannot be read. Prefers GetWindowLongPtr (present in this jw32:
  contract test CT-1 listed it) because GetWindowLong throws for styles with bit 31 set."
  [hwnd idx]
  (def f (or (opt "GetWindowLongPtr") GetWindowLong))
  (guarded nil (fn [] (bits-32 (f hwnd idx)))))

(defn facts
  "classify's facts (ADR 0008). Win32 only -- no UIA, because the poll calls this for every window."
  [hwnd]
  # jw32's GetWindowLong throws "out of range for 32-bit signed integers" for a window whose style has
  # bit 31 set (WS_POPUP: menus, many dialogs) -- seen in the contract test log. Such a window is still
  # reported; only the two style-derived facts become "unknown" (false).
  (def style (window-long hwnd GWL_STYLE))
  (def ex-style (window-long hwnd GWL_EXSTYLE))
  # :class and :title are NOT here: this jw32 has no GetClassName/GetWindowText (contract test CT-1).
  # The adapter reads them from the UIA element in the :window-created hook.
  {:exe (guarded nil (fn [] (util/get-hwnd-path hwnd)))
   :visible? (true? (IsWindowVisible hwnd))
   :minimized? (minimized? hwnd)
   :fullscreen? (and style (fullscreen? hwnd style))
   :tool-window? (and ex-style (not (zero? (band ex-style ws-ex-toolwindow))))
   :owned? (let [owner (GetWindow hwnd GW_OWNER)]
             # jw32 returns a NULL pointer, not nil, for "no owner" (Jwno itself tests `null?`)
             (not (or (nil? owner) (null? owner))))})

(defn window-rect
  "GetWindowRect as {:left :top :right :bottom}, or nil if it cannot be read (a dead window, ...)."
  [hwnd]
  (guarded nil (fn []
                 (def [ret rect] (GetWindowRect hwnd))
                 (when (true? ret)
                   {:left (in rect :left) :top (in rect :top) :right (in rect :right) :bottom (in rect :bottom)}))))

(def win32
  {:window-rect window-rect
   :foreground-hwnd foreground-hwnd
   :root-of root-of
   :hwnd->number hwnd->number
   :facts facts
   :desktop-guid desktop-guid
   :on-current-desktop? on-current-desktop?
   :minimized? minimized?
   :zoomed? zoomed?
   :mouse-down? mouse-down?
   :watch-moves watch-moves
   :unwatch-moves unwatch-moves
   :pump pump
   :hung? hung?
   :beep beep
   :swp-nomove-nosize (bor SWP_NOMOVE SWP_NOSIZE)})
