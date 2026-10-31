# Keymap as data. A binding is [key-string event], event = [:command name & args].
# Pure: parses and canonicalizes key strings, validates bindings against the
# commands the core knows, and detects clashes. The shell just registers the
# validated, canonical keys with Jwno and feeds the events to `update`.
#
# Key strings use Jwno's syntax: "Win + Shift + Q", "Alt + Enter", "Win + 1".

(import ./update)
(import ./layout)

(def mod-order ["Win" "Ctrl" "Alt" "Shift"])

(defn- canon-mod [s]
  (find |(= (string/ascii-lower $) (string/ascii-lower s)) mod-order))

(defn- canon-key [s]
  (if (= 1 (length s))
    (string/ascii-upper s)
    (string (string/ascii-upper (string/slice s 0 1))
            (string/ascii-lower (string/slice s 1)))))

(defn parse-key
  "-> {:mods [..] :key \"Q\"} or nil. Modifiers are order- and case-insensitive."
  [str]
  (when (and (string? str) (not (empty? str)))
    (def parts (map string/trim (string/split "+" str)))
    (when (and (not (empty? parts)) (all |(not (empty? $)) parts))
      (def key (last parts))
      (def mods (map canon-mod (slice parts 0 -2)))
      (when (and (not (canon-mod key))              # last token is a real key
                 (all identity mods)                # every other token is a modifier
                 (= (length mods) (length (distinct mods))))
        {:mods (tuple ;(filter |(index-of $ mods) mod-order))
         :key (canon-key key)}))))

(defn canonical
  "Canonical key string, or nil if `str` is not a valid key."
  [str]
  (when-let [{:mods mods :key key} (parse-key str)]
    (string/join [;mods key] " + ")))

(defn- check-event
  [event tags]
  (def [kind name & args] (if (indexed? event) event []))
  (cond
    (not= kind :command) "event must be [:command name ...]"
    (nil? (update/command-args name)) (string "unknown command " name)
    (let [want (update/command-args name)
          arg (first args)]
      (case want
        :none (if (empty? args) nil "takes no argument")
        :tag (if (and (= 1 (length args)) (index-of arg tags)) nil (string "needs one of the workspace tags, got " arg))
        :layout (if (and (= 1 (length args)) (index-of arg layout/layouts)) nil (string "needs a layout, got " arg))))))

(defn build
  "Validate bindings. -> {:keys {canonical-key event} :errors [string ...]}.
  Never throws; a bad binding is reported and left out."
  [bindings tags]
  (def keys @{})
  (def errors @[])
  (each b (if (indexed? bindings) bindings [])
    (def [k event] (if (indexed? b) b [nil nil]))
    (def ck (canonical k))
    (cond
      (nil? ck) (array/push errors (string "bad key " (string/format "%q" k)))
      (check-event event tags) (array/push errors (string ck ": " (check-event event tags)))
      (keys ck) (array/push errors (string ck ": bound twice"))
      (put keys ck (tuple ;event))))
  {:keys (table/to-struct keys) :errors (tuple ;errors)})

(defn lookup
  "Event for a key string, or nil."
  [km key-str]
  (when-let [ck (canonical key-str)]
    ((km :keys) ck)))

(defn default-bindings
  "xmonad's default bindings for `mod` ('Alt' or 'Win'), workspaces `tags`
  bound to 1..9 in order."
  [mod tags]
  (def m |(string mod " + " $))
  (def ms |(string mod " + Shift + " $))
  [;[[(m "J") [:command :focus-next]]
     [(m "K") [:command :focus-prev]]
     [(m "Tab") [:command :focus-next]]
     [(ms "Tab") [:command :focus-prev]]
     [(m "M") [:command :focus-master]]
     [(m "Enter") [:command :swap-master]]
     [(ms "J") [:command :swap-next]]
     [(ms "K") [:command :swap-prev]]
     [(m "H") [:command :shrink]]
     [(m "L") [:command :expand]]
     [(m "Comma") [:command :inc-master]]
     [(m "Period") [:command :dec-master]]
     [(m "Space") [:command :next-layout]]
     [(ms "C") [:command :close]]
     [(m "N") [:command :refresh]]]
   ;(seq [i :range [0 (min 9 (length tags))]]
      [(m (string (+ i 1))) [:command :goto (tags i)]])
   ;(seq [i :range [0 (min 9 (length tags))]]
      [(ms (string (+ i 1))) [:command :send (tags i)]])])
