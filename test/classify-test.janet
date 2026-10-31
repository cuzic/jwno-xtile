(use ./t)
(import ../src/core/classify :as c)

(def plain {:class "Notepad" :exe "C:\\Windows\\notepad.exe" :title "a.txt - Notepad"
            :visible? true})

(deftest "an ordinary window is tiled"
  (is= :tile (c/classify [] plain)))

(deftest "built-in: invisible, tool, minimized, fullscreen windows are ignored"
  (is= :ignore (c/classify [] (merge plain {:visible? false})))
  (is= :ignore (c/classify [] (merge plain {:tool-window? true})))
  (is= :ignore (c/classify [] (merge plain {:minimized? true})))
  (is= :ignore (c/classify [] (merge plain {:fullscreen? true}))))

(deftest "built-in: dialogs and owned windows float"
  (is= :float (c/classify [] (merge plain {:dialog? true})))
  (is= :float (c/classify [] (merge plain {:class "#32770"})))
  (is= :float (c/classify [] (merge plain {:owned? true}))))

(deftest "ignore beats float when both apply"
  (is= :ignore (c/classify [] (merge plain {:dialog? true :minimized? true}))))

(deftest "user rules run first, first match wins"
  (def rules [{:match {:exe "notepad.exe"} :action :float}
              {:match {:exe "notepad.exe"} :action :ignore}])
  (is= :float (c/classify rules plain))
  # and can override a built-in
  (is= :tile (c/classify [{:match {:class "#32770"} :action :tile}]
                         (merge plain {:class "#32770"}))))

(deftest "rule matching: exe suffix ignoring case, class exact, title substring"
  (is= :float (c/classify [{:match {:exe "NOTEPAD.EXE"} :action :float}] plain))
  (is= :tile (c/classify [{:match {:exe "pad.exe"} :action :float}] plain)) # not a path-component suffix
  (is= :float (c/classify [{:match {:class "Notepad"} :action :float}] plain))
  (is= :tile (c/classify [{:match {:class "note"} :action :float}] plain))
  (is= :float (c/classify [{:match {:title "A.TXT"} :action :float}] plain)))

(deftest "all keys of :match must hold"
  (def r [{:match {:exe "notepad.exe" :title "nope"} :action :float}])
  (is= :tile (c/classify r plain))
  (is= :float (c/classify [{:match {:exe "notepad.exe" :title "a.txt"} :action :float}] plain)))

(deftest "invalid rules are skipped, bad facts are ignored; never throws"
  (def bad [nil 5 {} {:match {} :action :float} {:match {:exe 1} :action :float}
            {:match {:nope "x"} :action :float} {:match {:exe "x"} :action :bogus}
            {:match {:visible? true} :action :float}])
  (is= :tile (c/classify bad plain))
  (is= :tile (c/classify nil plain))
  (is= :ignore (c/classify [] nil))
  (is= :ignore (c/classify [] 5)))

(deftest "missing optional facts count as absent"
  (is= :tile (c/classify [] {}))
  (is= :tile (c/classify [{:match {:exe "x.exe"} :action :float}] {})))

(deftest "C4: state facts beat user rules; hidden? agrees with classify"
  (def rules [{:match {:exe "notepad.exe"} :action :float}])
  (each f [{:visible? false} {:minimized? true} {:fullscreen? true}]
    (def facts (merge plain f))
    (is (c/hidden? facts))
    (is= :ignore (c/classify rules facts))
    (is= :ignore (c/classify [{:match {:exe "notepad.exe"} :action :tile}] facts)))
  (is (not (c/hidden? plain)))
  (is (not (c/hidden? {})))
  (is (not (c/hidden? nil))))

(deftest "tool windows are static: a user rule can still manage them"
  (def tw (merge plain {:tool-window? true}))
  (is= :ignore (c/classify [] tw))
  (is= :tile (c/classify [{:match {:exe "notepad.exe"} :action :tile}] tw)))
