# Which windows get tiled? A pure decision over facts the shell collected.
#
#   (classify rules facts) -> :tile | :float | :ignore
#
# facts: {:class "..." :exe "C:\\...\\app.exe" :title "..."
#         :visible? bool :minimized? bool :fullscreen? bool
#         :dialog? bool :tool-window? bool :owned? bool}
# Missing keys count as false / absent. facts may be a struct or a table: they
# are only read, never stored.
#
# Order: state facts (hidden?: invisible/minimized/fullscreen) always :ignore;
# then user rules, first match wins; then built-in defaults; then :tile.
#   {:match {:exe "wt.exe" :class "#32770" :title "substring"} :action :float}
# Every key in :match must hold (AND). :exe matches a path suffix, ignoring
# case; :class is exact; :title is a case-insensitive substring.

(def actions {:tile true :float true :ignore true})

(defn- lower [x] (string/ascii-lower (string x)))

(defn- matches?
  [spec facts]
  (and (not (empty? spec))
       (all
         (fn [[k v]]
           (case k
             :exe (let [e (get facts :exe)]
                    (and (string? e)
                         (string/has-suffix? (string "\\" (lower v)) (string "\\" (lower e)))))
             :class (= v (get facts :class))
             :title (let [t (get facts :title)]
                      (and (string? t) (not (nil? (string/find (lower v) (lower t))))))
             false))
         (pairs spec))))

(defn valid-rule?
  [rule]
  (and (struct? rule)
       (actions (get rule :action))
       (struct? (get rule :match))
       (not (empty? (rule :match)))
       (all |(index-of $ [:exe :class :title]) (keys (rule :match)))
       (all |(string? $) (values (rule :match)))))

(defn hidden?
  "State facts that take a window out of management whatever the user rules
  say (ADR 0008, C4): invisible, minimized, fullscreen. Total."
  [facts]
  (and (dictionary? facts)
       (or (false? (get facts :visible?))
           (truthy? (get facts :minimized?))
           (truthy? (get facts :fullscreen?)))))

# Built-in defaults after the user rules, in priority order. Not data-driven
# on purpose: they read boolean facts, which rules cannot express.
(defn- builtin
  [facts]
  (cond
    (get facts :tool-window?) :ignore
    (or (get facts :dialog?) (= "#32770" (get facts :class))) :float
    (get facts :owned?) :float
    nil))

(defn classify
  "Total: bad rules are skipped, bad facts classify as :ignore."
  [rules facts]
  (cond
    (not (dictionary? facts)) :ignore
    (hidden? facts) :ignore
    (let [hit (find |(and (valid-rule? $) (matches? ($ :match) facts))
                    (if (indexed? rules) rules []))]
      (if hit
        (hit :action)
        (or (builtin facts) :tile)))))
