# Whole-WM state. Plain immutable data; no handles, no I/O.
#   :screen      work-area rect of the (single, for now) monitor
#   :tags        workspace tags, in order
#   :current     tag of the visible workspace
#   :workspaces  {tag workspace}
#   :rules       classify rules (tuple of struct), fixed at make
#   :floating    {id true}: a subset of the windows on the workspaces. Floats stay
#                in the stack (as in xmonad) and are only left out of the layout.

(import ./data :as d)
(import ./workspace :as ws)
(import ./layout)
(import ./classify)

(defn make [screen tags &opt rules stray-mode]
  (default rules [])
  (assert (index-of stray-mode [nil :return :follow]) "stray-mode must be :return or :follow")
  (assert (and (indexed? rules) (all classify/valid-rule? rules))
          "rules must be a list of valid classify rules")
  (assert (and (not (empty? tags)) (all string? tags))
          "workspace tags must be a non-empty list of strings")
  (def base
  {:screen screen
   :tags (tuple ;tags)
   :rules (tuple ;rules)
   :floating {}
   :current (first tags)
   :workspaces (struct ;(mapcat |[$ (ws/make $)] tags))})
  # ADR 0006 D-7e: what to do when the OS focus rests on a parked window (default :return)
  (if (= stray-mode :follow) (d/assoc base {:stray-mode :follow}) base))

(defn ws-of [s tag] ((s :workspaces) tag))

# ADR 0012 stage 1a: the visible workspace and the screen rect are read and written ONLY through these four
# functions, so stage 1b can change the representation (:screens, :focused-screen) in one place.
(defn current "tag of the workspace on the focused screen" [s] (s :current))
(defn screen "work-area rect of the focused screen" [s] (s :screen))
(defn set-current [s tag] (d/assoc s {:current tag}))
(defn set-screen [s rect] (d/assoc s {:screen rect}))

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

(defn placements
  "{id rect} for every tiled window on the visible workspace (never a float)."
  [s]
  (def w (current-ws s))
  (table/to-struct
    (from-pairs (layout/arrange (w :layout) w (screen s) (tiled-ids s w)))))

(defn focused [s] ((current-ws s) :focus))
