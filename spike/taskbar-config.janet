# SPIKE for ADR 0011 stage 0: can ITaskbarList::DeleteTab take another process's window off the taskbar,
# called through Janet's FFI from Jwno's main thread (COM is already initialised there)? Measurements only.
# Run by spike/run-taskbar.ps1 (hotkeys: Alt+Shift+F7 = DeleteTab, F6 = AddTab, F5 = find the window).
(use jw32/_winuser)
(use jw32/_util)
(import jwno/util)

(def out-path (or (os/getenv "TB_OUT") "taskbar.log"))
(defn rec [what & xs]
  (def f (file/open out-path :a))
  (when f
    (file/write f (string/format "%.3f %s %s\n" (os/clock :realtime) what
                                 (string/join (map |(string/format "%q" $) xs) " ")))
    (file/flush f) (file/close f)))
(rec :config-start)

(def ffi-native (get-in root-env [(symbol "ffi/native") :value]))
(def ffi-lookup (get-in root-env [(symbol "ffi/lookup") :value]))
(def ffi-call (get-in root-env [(symbol "ffi/call") :value]))
(def ffi-sig (get-in root-env [(symbol "ffi/signature") :value]))
(def ffi-read (get-in root-env [(symbol "ffi/read") :value]))

(defn guid-buffer [d1 d2 d3 bytes]
  (def b (buffer/new-filled 16 0))
  (def le (fn [n w] (seq [i :range [0 w]] (band (brshift n (* 8 i)) 0xFF))))
  (var o 0)
  (each x [;(le d1 4) ;(le d2 2) ;(le d3 2) ;bytes] (put b o x) (++ o))
  b)

# CLSID_TaskbarList {56FDF344-FD6D-11D0-958A-006097C9A090}, IID_ITaskbarList {56FDF342-FD6D-11D0-958A-006097C9A090}
(def clsid (guid-buffer 0x56FDF344 0xFD6D 0x11D0 [0x95 0x8A 0x00 0x60 0x97 0xC9 0xA0 0x90]))
(def iid (guid-buffer 0x56FDF342 0xFD6D 0x11D0 [0x95 0x8A 0x00 0x60 0x97 0xC9 0xA0 0x90]))

(var tbl nil)       # the ITaskbarList pointer
(var vtbl nil)
(defn slot [i] (ffi-read :ptr vtbl (* 8 i)))

(defn init-taskbar []
  (def ole (ffi-native "ole32.dll"))
  (def cci (ffi-lookup ole "CoCreateInstance"))
  (def out (buffer/new-filled 8 0))
  (def hr (ffi-call cci (ffi-sig :default :int :ptr :ptr :uint :ptr :ptr) clsid nil 1 iid out))
  (rec :cocreate hr)
  (when (zero? hr)
    (set tbl (ffi-read :ptr out))
    (set vtbl (ffi-read :ptr tbl))
    (def hr-init (ffi-call (slot 3) (ffi-sig :default :int :ptr) tbl))
    (rec :hrinit hr-init)))

(defn tb-call [i label]
  (try
    (do
      (unless tbl (init-taskbar))
      (def h (FindWindowEx nil nil "Notepad" nil))
      (if (null? h)
        (rec :no-window label)
        (let [hr (ffi-call (slot i) (ffi-sig :default :int :ptr :ptr) tbl h)]
          (rec label hr (util/pointer-to-number h)))))
    ([e] (rec :error label (string e)))))

(def key-man (in jwno/context :key-manager))
(def keymap (:new-keymap key-man))
(def cmd (in jwno/context :command-manager))
(:add-command cmd :tb-delete (fn [] (tb-call 5 :delete-tab)))
(:add-command cmd :tb-add (fn [] (tb-call 4 :add-tab)))
(:add-command cmd :tb-find (fn [] (rec :find (let [h (FindWindowEx nil nil "Notepad" nil)] (if (null? h) :none (util/pointer-to-number h))))))
(:define-key keymap "Alt+Shift+F7" :tb-delete)
(:define-key keymap "Alt+Shift+F6" :tb-add)
(:define-key keymap "Alt+Shift+F5" :tb-find)
(:set-keymap key-man keymap)
(rec :config-end)
