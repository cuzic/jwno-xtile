# Whole-WM state. Plain immutable data; no handles, no I/O.
#   :screens     (ADR 0012) tuple of {:rect work-area :ws tag :device name-or-absent}, one per monitor, in display
#                order; each workspace is on at most one screen. `:focused-screen` is the index of the focused one.
#                The workspace and rect of the focused screen are read ONLY through `current` / `screen`.
#   :tags        workspace tags, in order
#   :workspaces  {tag workspace}
#   :rules       classify rules (tuple of struct), fixed at make
#   :floating    {id true}: a subset of the windows on the workspaces. Floats stay
#                in the stack (as in xmonad) and are only left out of the layout.

(import ./data :as d)
(import ./workspace :as ws)
(import ./layout)
(import ./classify)

(defn make
  "`screen` is one work-area rect (a single monitor) or a list of rects (ADR 0012: one per monitor, in display
  order; the first tags are shown on them in order, as xmonad does)."
  [screen tags &opt rules stray-mode]
  (default rules [])
  (assert (index-of stray-mode [nil :return :follow]) "stray-mode must be :return or :follow")
  (assert (and (indexed? rules) (all classify/valid-rule? rules))
          "rules must be a list of valid classify rules")
  (assert (and (not (empty? tags)) (all string? tags))
          "workspace tags must be a non-empty list of strings")
  (def rects (if (indexed? screen) screen [screen]))
  (assert (and (not (empty? rects)) (<= (length rects) (length tags))) "need at least as many workspaces as screens")
  (def base
  {:screens (tuple ;(seq [i :range [0 (length rects)]] {:rect (rects i) :ws (tags i)}))
   :focused-screen 0
   :tags (tuple ;tags)
   :rules (tuple ;rules)
   :floating {}
   :workspaces (struct ;(mapcat |[$ (ws/make $)] tags))})
  # ADR 0006 D-7e: what to do when the OS focus rests on a parked window (default :return)
  (if (= stray-mode :follow) (d/assoc base {:stray-mode :follow}) base))

(defn ws-of [s tag] ((s :workspaces) tag))

# ADR 0012 stage 1a: the visible workspace and the screen rect are read and written ONLY through these four
# functions, so stage 1b can change the representation (:screens, :focused-screen) in one place.
(defn- focused-screen-entry [s] ((s :screens) (s :focused-screen)))
(defn current "tag of the workspace on the focused screen" [s] ((focused-screen-entry s) :ws))
(defn screen "work-area rect of the focused screen" [s] ((focused-screen-entry s) :rect))

(defn- update-screen [s i f]
  (d/assoc s {:screens (tuple ;(seq [k :range [0 (length (s :screens))]]
                                   (if (= k i) (f ((s :screens) k)) ((s :screens) k))))}))

(defn visible-tags "the workspaces shown on some screen" [s] (map |($ :ws) (s :screens)))
(defn screen-of "index of the screen that shows `tag`, or nil" [s tag] (find |(= tag (((s :screens) $) :ws)) (range (length (s :screens)))))
(defn visible-tag? [s tag] (not (nil? (screen-of s tag))))

(defn set-current
  "Show `tag` on the focused screen. If another screen already shows it, the focus moves to that screen (xmonad's
  `view`); the focused screen keeps its workspace."
  [s tag]
  (if-let [k (screen-of s tag)]
    (d/assoc s {:focused-screen k})
    (update-screen s (s :focused-screen) |(d/assoc $ {:ws tag}))))

(defn greedy-view
  "xmonad's `greedyView` (the default mod-N): if another screen shows `tag`, the two screens swap their workspaces
  (the focus stays on the focused screen); otherwise it is the same as showing `tag` on the focused screen."
  [s tag]
  (def f (s :focused-screen))
  (def k (screen-of s tag))
  (cond
    (nil? k) (set-current s tag)
    (= k f) s
    (let [mine (current s)]
      (-> s
          (update-screen k |(d/assoc $ {:ws mine}))
          (update-screen f |(d/assoc $ {:ws tag}))))))

(defn set-screen [s rect] (update-screen s (s :focused-screen) |(d/assoc $ {:rect rect})))

(defn current-ws [s] (ws-of s (current s)))

(defn locate
  "Tag of the workspace that holds `id`, or nil."
  [s id]
  (find |(ws/has? ((s :workspaces) $) id) (s :tags)))

(defn update-ws [s tag f]
  (d/assoc s {:workspaces (d/assoc (s :workspaces) {tag (f ((s :workspaces) tag))})}))

(defn update-current [s f] (update-ws s (current s) f))

(defn floating? [s id] (truthy? (get (s :floating) id)))

(defn tiled-ids
  "Ids of workspace `w` that take part in the layout: the stack minus floats."
  [s w]
  (tuple ;(filter |(not (floating? s $)) (w :ids))))

(defn vis-ids "ids of every window on a visible workspace (all screens)" [s]
  (mapcat |((ws-of s $) :ids) (visible-tags s)))

(defn placements
  "{id rect} for every tiled window on a visible workspace (never a float), each in its own screen's rect."
  [s]
  (table/to-struct
    (from-pairs
      (mapcat (fn [scr]
                (def w (ws-of s (scr :ws)))
                (layout/arrange (w :layout) w (scr :rect) (tiled-ids s w)))
              (s :screens)))))

(defn focused [s] ((current-ws s) :focus))
