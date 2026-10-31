# Jwno config used only by the spike: logs what Jwno's hooks report, in order.
# Output file: $SPIKE_LOG (one line per event, monotonic seconds first).
(use jw32/_winuser)

(def log-path (or (os/getenv "SPIKE_LOG") "spike-hooks.log"))
(def out (file/open log-path :a))

(defn rec [what & xs]
  (def fg (try (GetForegroundWindow) ([_] :err)))
  (file/write out (string/format "%.3f %s fg=%q %s\n" (os/clock :monotonic) what fg
                                 (string/join (map |(string/format "%q" $) xs) " ")))
  (file/flush out))

(def hook-man (in jwno/context :hook-manager))

(rec :config-loaded)

(:add-hook hook-man :filter-window
   (fn spike-filter [hwnd uia-win exe-path desktop-info]
     (rec :filter-window hwnd (try (:get_CachedClassName uia-win) ([_] :err)) exe-path desktop-info)
     true))

(:add-hook hook-man :window-created
   (fn [win _uia-win exe-path desktop-info]
     (rec :window-created (in win :hwnd) exe-path desktop-info)))

(:add-hook hook-man :window-removed
   (fn [win] (rec :window-removed (in win :hwnd))))

(:add-hook hook-man :focus-changed
   (fn [hwnd] (rec :focus-changed hwnd)))

(:add-hook hook-man :window-activated
   (fn [win] (rec :window-activated (in win :hwnd))))

(:add-hook hook-man :virtual-desktop-changed
   (fn [& args] (rec :virtual-desktop-changed ;args)))

(:add-hook hook-man :frame-activated
   (fn [fr] (rec :frame-activated)))

# What does Jwno think the desktops are?
(ev/spawn
  (try
    (rec :all-desktops (:get-all-desktops (in jwno/context :virtual-desktop-manager)))
    ([e] (rec :all-desktops-error e))))
