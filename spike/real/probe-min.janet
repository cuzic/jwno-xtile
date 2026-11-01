# Manages NOTHING (filter-window is always false) and says when the config was evaluated.
(def out (file/open (os/getenv "PROBE_OUT") :a))
(defn rec [& xs]
  (file/write out (string/format "%.3f %s\n" (os/clock :realtime) (string/join (map string xs) " ")))
  (file/flush out))
(rec "config-start")
(def hook-man (in jwno/context :hook-manager))
(:add-hook hook-man :filter-window (fn [& _] false))
(rec "config-end")
