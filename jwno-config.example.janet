# Example Jwno config for jwno-xtile (ADR 0010).
#
#   jwno.exe --mod-path C:\path\to\jwno-xtile --config C:\path\to\jwno-xtile\jwno-config.example.janet
#
# `--mod-path` makes the repository root the module root, so `src/...` resolves (verified on hosted Windows
# and one real Windows 11 PC). Copying `src/` next to this file also works.
#
# What this does:  Core decides layout and focus; Jwno only reports windows and moves them where
# the core says. Jwno's own placement is switched off per window (swp-flags), and Jwno's own frame
# commands are NOT bound.

(import jwno/log)
(import src/jwno/adapter :as adapter)
(import src/jwno/win32 :as w32)
(import src/core/keymap :as km)

(def key-man (in jwno/context :key-manager))
(def keymap (:new-keymap key-man))

(defn xtile-log [level msg]
  (case level
    :debug (log/debug "xtile: %s" msg)
    :info (log/info "xtile: %s" msg)
    :warn (log/warning "xtile: %s" msg)
    (log/error "xtile: %s" msg)))

(def xtile
  (adapter/install
    jwno/context w32/win32
    {:log xtile-log
     :keymap keymap
     # Alt-based xmonad bindings; change "Alt" to "Win" for the Win key
     :bindings (km/default-bindings "Alt" adapter/default-tags)
     # user rules for the tile / float / ignore decision (ADR 0008)
     :rules [{:match {:class "#32770"} :action :float}]
     :poll-seconds 2
     # Space between tiles and round the screen, in pixels (ADR 0013). 0 = no spacing, exactly xmonad's layout.
     # :gap 8
     # :padding 8
     # Take the taskbar button of a window of another workspace away (it is parked off-screen but still a window).
     # ITaskbarList::DeleteTab through Janet's FFI; verified on one Windows 11 desktop (ADR 0011), UNVERIFIED with
     # several Windows virtual desktops. The window stays in Alt-Tab. Off by default.
     # :hide-taskbar-button true
     # Several monitors (opt in, unverified on real hardware). Off: only the main monitor is managed.
     # :multi-monitor? true
     }))

(:set-keymap key-man keymap)

# the hooks are registered now; sync with the OS and start polling
((xtile :start))
