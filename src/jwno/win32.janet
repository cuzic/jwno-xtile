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
(use jw32/_libloaderapi)
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

# ---- the sink window (ADR 0006 D-7b, rev. 4d): holds the OS focus when the visible workspace is empty ----
# It lives on Jwno's UI thread (the only thread there that pumps messages), so the window procedure and the
# three handlers below are marshalled over there: they may use jw32 and constants only, no closures over
# anything else. Spike: spike/sink-config.janet + spike/run-sink.ps1 (hosted Windows Server 2022: window
# created, answers messages, swallows keys and Alt+F4, Jwno's own key bindings still work in front of it,
# and `SetForegroundWindow` works from the UI thread after a synthetic Alt tap; UIA SetFocus does not).
# UNVERIFIED on a real desktop: IME, Narrator, the foreground lock without a preceding Alt tap.

(defn- sink-wndproc [hwnd msg wparam lparam]
  (cond
    (or (= msg WM_KEYDOWN) (= msg WM_KEYUP) (= msg WM_CHAR)
        (= msg WM_SYSKEYDOWN) (= msg WM_SYSKEYUP) (= msg WM_SYSCHAR))
    0                                                          # keys typed into the sink go nowhere
    (= msg WM_CLOSE) 0                                         # nor can it be closed
    (= msg WM_SYSCOMMAND)
    (if (= (band (int/to-number wparam) 0xFFF0) 0xF060)        # SC_CLOSE (Alt+F4)
      0
      (DefWindowProc hwnd msg wparam lparam))
    (DefWindowProc hwnd msg wparam lparam)))

(defn- sink-create [_hwnd _msg _wparam _lparam _hook state]
  # a sink that was destroyed some other way is made again (Opus F-L1)
  (when-let [old (in state :xtile-sink)]
    (when (= FALSE (IsWindow old)) (put state :xtile-sink nil)))
  (if-let [old (in state :xtile-sink)]
    (util/pointer-to-number old)
    (do
      # a second RegisterClassEx (after a destroy) fails because the class exists: that is fine
      (RegisterClassEx (WNDCLASSEX :lpfnWndProc sink-wndproc
                                   :hInstance (GetModuleHandle nil)
                                   :lpszClassName "xtile-sink"
                                   :hCursor (LoadCursor nil IDC_ARROW)))
      (def h (CreateWindowEx WS_EX_TOOLWINDOW "xtile-sink" "xtile: 空のワークスペース"
                             WS_POPUP -32000 -32000 1 1 nil nil (GetModuleHandle nil) nil))
      (if (null? h)
        0
        (do (put state :xtile-sink h)
            (ShowWindow h SW_SHOWNOACTIVATE)
            (util/pointer-to-number h))))))

(defn- sink-front [_hwnd _msg _wparam _lparam _hook state]
  (def h (in state :xtile-sink))
  (defn fg? [] (= (util/pointer-to-number (GetForegroundWindow)) (util/pointer-to-number h)))
  (defn alt-tap []
    (SendInput [(INPUT :type INPUT_KEYBOARD :ki.wVk 0x12 :ki.dwFlags 0)
                (INPUT :type INPUT_KEYBOARD :ki.wVk 0x12 :ki.dwFlags KEYEVENTF_KEYUP)]))
  # Opus F-M1: an injected Alt would break a modifier the user is holding (Alt+3 held down ...): then do
  # not inject; the refusal is retried by :reclaim-focus once the keys are up
  (defn modifier-down? []
    (some (fn [vk] (neg? (int/to-number (GetAsyncKeyState vk)))) [0x12 0x10 0x11 0x5B 0x5C]))
  (if (nil? h)
    0
    (do
      (var ok false)
      (SetForegroundWindow h)
      (set ok (fg?))
      (when (and (not ok) (not (modifier-down?)))       # the variant that worked in the spike
        (alt-tap) (SetForegroundWindow h) (set ok (fg?)))
      (if ok 1 0))))

(defn- sink-destroy [_hwnd _msg _wparam _lparam _hook state]
  (when-let [h (in state :xtile-sink)]
    (DestroyWindow h)
    (put state :xtile-sink nil))
  0)

(defn make-focus-sink
  "-> {:front () -> bool, :hwnd-number () -> number|nil, :destroy ()}. The window is made on first use and
  made again if it was destroyed. A refusal (foreground lock) is `false`, not an error."
  [ui-man]
  (def ids @{})
  (var hwnd-n nil)
  (defn ensure []
    (unless (ids :create)
      (put ids :create (:add-custom-message ui-man sink-create))
      (put ids :front (:add-custom-message ui-man sink-front))
      (put ids :destroy (:add-custom-message ui-man sink-destroy))))
  @{:front (fn []
             (ensure)
             (def n (num (:send-message ui-man (ids :create) 0 0)))
             (set hwnd-n (if (zero? n) nil n))
             (and hwnd-n (= 1 (num (:send-message ui-man (ids :front) 0 0)))))
    :hwnd-number (fn [] hwnd-n)
    :destroy (fn []
               (when (ids :destroy) (:send-message ui-man (ids :destroy) 0 0))
               (set hwnd-n nil))})

(defn maximize
  "ShowWindow(SW_MAXIMIZE). Jwno's transform (the park) un-maximises a window; this puts it back."
  [hwnd]
  (guarded nil (fn [] (ShowWindow hwnd SW_MAXIMIZE) true)))

(defn window-rect
  "GetWindowRect as {:left :top :right :bottom}, or nil if it cannot be read (a dead window, ...)."
  [hwnd]
  (guarded nil (fn []
                 (def [ret rect] (GetWindowRect hwnd))
                 (when (true? ret)
                   {:left (in rect :left) :top (in rect :top) :right (in rect :right) :bottom (in rect :bottom)}))))

(def win32
  {:make-focus-sink make-focus-sink
   :maximize maximize
   :window-rect window-rect
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
