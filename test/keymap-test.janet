(use ./t)
(import ../src/core/keymap :as k)
(import ../src/core/update :as u)
(import ../src/core/state :as st)
(import ../src/core/geometry :as g)

(def tags ["1" "2" "3" "4" "5" "6" "7" "8" "9"])

(deftest "canonical keys ignore case, spacing and modifier order"
  (def want "Win + Shift + Q")
  (is= want (k/canonical "Win + Shift + Q"))
  (is= want (k/canonical "shift+win+q"))
  (is= want (k/canonical " SHIFT  +  Win + q "))
  (is= "Win + Enter" (k/canonical "win + ENTER"))
  (is= "Win + 1" (k/canonical "Win+1"))
  (is= "Win + Ctrl + Alt + Shift + F5" (k/canonical "shift+alt+ctrl+win+f5")))

(deftest "invalid key strings are rejected"
  (each bad ["" "+" "Win +" "+ Q" "Win + Win + Q" "Win + Shift" "Shift" "a + b" nil 5 :x]
    (is= nil (k/canonical bad))))

(deftest "build keeps good bindings, reports bad ones, never throws"
  (def km (k/build [["Win + J" [:command :focus-next]]
                    ["bogus +" [:command :focus-next]]
                    ["Win + K" [:command :nope]]
                    ["Win + L" [:command :goto "99"]]
                    ["Win + M" [:command :goto]]
                    ["Win + N" [:command :close :extra]]
                    ["win + j" [:command :focus-prev]]
                    ["Win + O" [:set-layout :tall]]
                    ["Win + P" 5]
                    5]
                   tags))
  (is= ["Win + J"] (tuple ;(sort (array ;(keys (km :keys))))))
  (is= 9 (length (km :errors)))
  (is= [:command :focus-next] (k/lookup km "WIN+j")))

(deftest "set-layout validates the layout name"
  (def km (k/build [["Win + A" [:command :set-layout :wide]]
                    ["Win + B" [:command :set-layout :bogus]]] tags))
  (is= ["Win + A"] (tuple ;(sort (array ;(keys (km :keys))))))
  (is= 1 (length (km :errors))))

(deftest "default xmonad bindings are valid for Alt and Win, with no clashes"
  (each mod ["Alt" "Win"]
    (def km (k/build (k/default-bindings mod tags) tags))
    (is= [] (km :errors))
    (is= (length (k/default-bindings mod tags)) (length (km :keys)))))

(deftest "default bindings cover every core command (xmonad leaves some unbound; :view has none, mod-N is greedyView)"
  (def km (k/build (k/default-bindings "Alt" tags) tags))
  (def bound (distinct (map |($ 1) (values (km :keys)))))
  (each name (keys u/command-args)
    (unless (or (index-of name [:set-layout :shift-master :toggle-float :view :set-gap :set-padding :inc-gap :dec-gap])
                (= :internal (u/command-args name)))
      (is (index-of name bound)))))

(deftest "internal commands cannot be bound"
  (def km (k/build [["Alt + X" [:command :reassert-focus]]] tags))
  (is= {} (km :keys))
  (is= 1 (length (km :errors))))

(deftest "every default binding drives update without throwing"
  (def km (k/build (k/default-bindings "Alt" tags) tags))
  (var s (st/make (g/rect 0 0 1000 600) tags))
  (set s ((u/update s [:window-opened :a]) :state))
  (set s ((u/update s [:window-opened :b]) :state))
  (set s ((u/update s [:focus-changed :b]) :state))
  (each ev (values (km :keys))
    (is (st/current-ws ((u/update s ev) :state)))))

(deftest "Alt+1..9 jump to workspaces and Alt+Shift+1..9 send"
  (def km (k/build (k/default-bindings "Alt" tags) tags))
  (is= [:command :goto "3"] (k/lookup km "alt+3"))
  (is= [:command :send "3"] (k/lookup km "Alt + Shift + 3")))
