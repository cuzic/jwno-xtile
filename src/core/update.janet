# (update state event) -> {:state s' :effects [effect ...]}
#
# Events (input data):
#   [:window-opened id &opt tag]      [:window-closed id]
#   [:window-seen id facts &opt tag]  (ADR 0008: classify once; later only hiding)
#   [:window-dragged id rect]         (the user moved/resized it: floats, if rect differs from our placement)
#   [:focus-changed id-or-nil]        [:desktop-changed tag]
#   [:screen-changed rect]            [:window-moved id observed-rect]
#   [:windows-observed [[id tag-or-nil] ...]]   (snapshot, first = topmost)
#   [:command name & args]            (incl. :refresh)
#
# Effects (output data, executed by the shell):
#   [:place id rect]  [:focus id]  [:close id]
#   [:goto tag]       [:send id tag]
#   [:hide id] [:show id]   (ADR 0006: derived from which workspace is visible)
#
# :place / :focus effects are derived by diffing old and new state, so the
# transitions below never mention them.
#
# Observation principle: facts about the OS come only from observation events,
# and the model never assumes one of its own effects succeeded.
#  * :os-focus = the last OS focus we observed (any valid id, even unknown or on
#    another workspace); absent = unknown. Destructive commands (close, send,
#    reorder) run ONLY when the model's focus equals :os-focus ("actionable"),
#    so they can only ever hit the window the user is looking at -- even if a
#    :focus effect of ours failed (foreground lock).
#  * :focus-changed / :desktop-changed update the model but never echo a
#    :focus effect back (silent).
#  * :external-focus (OS focus is on something we do not manage) is set and
#    cleared ONLY by observations (an observed focus, or a window-opened for
#    the very id last observed as OS focus). While set, no :focus is derived
#    (we never steal focus from a dialog).
#  * :current changes only on :desktop-changed or the :goto command.
#
# Recovery from drift: [:command :refresh] re-emits every :place (and :focus
# when not external); [:window-moved id rect] re-places one window unless the
# observed rect already matches the model (so our own :place echoes die out),
# and gives up after `misfit-limit` consecutive mismatches (app enforces its
# own size); [:windows-observed ...] repairs the model itself (ghost ids,
# wrong workspace).
#
# Core never throws: malformed or ill-typed events are ignored.

(import ./data :as d)
(import ./state :as st)
(import ./workspace :as ws)
(import ./layout)
(import ./classify :as cl)

(def- ratio-step 0.03)
(def- misfit-limit 3)

# ---- validation --------------------------------------------------------

(defn- valid-id? [x] (or (number? x) (keyword? x) (string? x)))

(defn- int? [x]
  (and (number? x) (= x (math/floor x)) (< (math/abs x) 1e9)))

(defn- valid-rect? [r]
  (and (struct? r)
       (int? (get r :x)) (int? (get r :y)) (int? (get r :w)) (int? (get r :h))
       (pos? (r :w)) (pos? (r :h))))

(defn- valid-tag? [s tag] (and (string? tag) (not (nil? (index-of tag (s :tags))))))

(defn- known? [s id] (not (nil? (st/locate s id))))
(defn- external? [s] (s :external-focus))

(defn- actionable?
  "True only if the model's focused window is the one the OS last reported."
  [s]
  (def f (st/focused s))
  (and f (= f (s :os-focus))))

# ---- observations ------------------------------------------------------

(defn- hidden-tag
  "Opus M4: the workspace a window was on when it was dropped for being minimised/fullscreen, if that
  workspace still exists. A window that comes back goes home instead of to the workspace we look at."
  [s id]
  (def t (get-in s [:hidden-from id]))
  # Opus F-H1: a window that is the OS focus when it returns was activated by the user (taskbar, Alt-Tab):
  # it belongs where they are looking. Only a quiet restore (no activation) goes home.
  (when (and t (valid-tag? s t) (not= id (s :os-focus))) t))

(defn- forget-hidden-from [s id]
  (if (get-in s [:hidden-from id])
    (d/assoc s {:hidden-from (d/without (s :hidden-from) id)})
    s))

(defn- open-window [s0 id tag]
  (def s (if (valid-id? id) (forget-hidden-from s0 id) s0))
  (cond
    (not (valid-id? id)) s
    (known? s id) s
    (and tag (not (valid-tag? s tag))) s
    (let [tag (or tag (hidden-tag s0 id) (s :current))
          s2 (st/update-ws s tag |(ws/insert $ id))]
      # Jwno reports focus on a new hwnd BEFORE :window-opened, and does not
      # repeat it. If this is the window the OS already focused, adopt that
      # observation instead of waiting for one that will never come.
      (if (and (= tag (s :current)) (= id (s :os-focus)))
        (d/assoc s2 {:external-focus false})
        s2))))

(defn- close-window [s id]
  (def tag (st/locate s id))
  (def s1 (if tag (st/update-ws s tag |(ws/remove $ id)) s))
  # forget everything keyed on this id: HWNDs get reused
  (def s1a (forget-hidden-from s1 id))
  (def s1b (if (get-in s1a [:floating id])
             (d/assoc s1a {:floating (d/without (s1a :floating) id)})
             s1a))
  (def s2 (if (get-in s1b [:misfit id])
            (d/assoc s1b {:misfit (d/without (s1b :misfit) id)})
            s1b))
  (if (= id (s2 :os-focus)) (d/without s2 :os-focus) s2))

(defn- set-floating [s id on?]
  (d/assoc s {:floating (if on?
                          (d/assoc (s :floating) {id true})
                          (d/without (s :floating) id))
              :misfit (d/without (get s :misfit {}) id)}))

(defn- drop-hidden
  "A known window became hidden (minimized, fullscreen, ...). If it holds the OS
  focus, keep that observation and mark focus external: the OS focus is now on
  something we do not manage, so we must not pull it to a neighbour (ADR 0008)."
  [s id]
  (def home (st/locate s id))
  (def s2a (close-window s id))
  (def s2 (if home (d/assoc s2a {:hidden-from (d/assoc (get s2a :hidden-from {}) {id home})}) s2a))
  (if (= id (s :os-focus))
    (d/assoc s2 {:os-focus id :external-focus true})
    s2))

(defn- window-seen
  "Classify once, when a window becomes known; afterwards only hiding it matters."
  [s id facts tag]
  (cond
    (or (not (valid-id? id)) (not (dictionary? facts))) s
    (known? s id) (if (cl/hidden? facts) (drop-hidden s id) s)
    (case (cl/classify (s :rules) facts)
      :tile (open-window s id tag)
      :float (let [s2 (open-window s id tag)]
               (if (known? s2 id) (set-floating s2 id true) s2))
      s)))

(defn- focus-window
  "OS focus moved. Record it; it clears `external` only when it lands on a
  window of the visible workspace. A window of another workspace is the
  pending half of a desktop switch: remember it in :os-focus (a following
  :desktop-changed adopts it), and treat focus as external meanwhile."
  [s id]
  (def tag (if (valid-id? id) (st/locate s id)))
  (cond
    (not (valid-id? id)) (-> s (d/assoc {:external-focus true}) (d/without :os-focus))
    # a window we do not know (yet): remember it, so a following :window-opened
    # for the same id is recognised as the focused one
    (nil? tag) (d/assoc s {:external-focus true :os-focus id})
    (not= tag (s :current))
    (d/assoc s {:external-focus true :os-focus id})
    (-> s
        (st/update-ws tag |(ws/focus-id $ id))
        (d/assoc {:external-focus false :os-focus id}))))

(defn- desktop-changed [s tag]
  (cond
    (not (valid-tag? s tag)) s
    (= tag (s :current)) s
    (let [id (s :os-focus)
          s2 (-> s (d/assoc {:current tag}) (d/without :os-focus))]
      (if (and id (= tag (st/locate s2 id)))
        (-> s2
            (st/update-ws tag |(ws/focus-id $ id))
            (d/assoc {:external-focus false :os-focus id}))
        (d/assoc s2 {:external-focus true})))))

(defn- windows-observed
  "Snapshot of what the OS actually has: [[id tag-or-nil] ...], first = topmost
  = master. Drops ghost ids, adds missing windows, fixes wrong workspaces. It
  is a pure observation of the window set: it returns no :focus and moves focus
  only to adopt an already-observed OS focus. A nil tag means
  'desktop unknown': a known window stays where it is, an unknown one goes to
  the visible workspace."
  [s obs]
  (if-not (indexed? obs)
    s
    (let [pairs (filter |(and (indexed? $) (valid-id? (get $ 0))
                              (or (nil? (get $ 1)) (valid-tag? s (get $ 1))))
                        obs)
          # the first occurrence of an id wins (including its facts)
          first-seen (table)
          pairs (filter |(if (first-seen (first $)) false (put first-seen (first $) true))
                        pairs)
          # an optional 3rd element is facts; invalid facts count as absent
          facts-of (fn [e] (let [f (get e 2)] (if (dictionary? f) f)))
          hidden-ids (filter |(let [f (facts-of $)] (and f (cl/hidden? f))) pairs)
          s0 (reduce (fn [a e] (if (known? a (first e)) (drop-hidden a (first e)) a))
                     s hidden-ids)
          pairs (filter |(let [f (facts-of $)] (not (and f (cl/hidden? f)))) pairs)
          # unknown windows the rules say to ignore stay out of the set
          pairs (filter |(let [f (facts-of $)]
                           (or (nil? f) (known? s0 (first $))
                               (not= :ignore (cl/classify (s0 :rules) f))))
                        pairs)
          seen (table)
          ordered (filter |(if (seen (first $)) false (put seen (first $) true))
                          pairs)
          s1 (reduce (fn [acc tag]
                       (reduce (fn [a id] (if (seen id) a (close-window a id)))
                               acc ((st/ws-of acc tag) :ids)))
                     s0 (s0 :tags))]
      (let [acc (reduce
                  (fn [acc [id tag facts]]
                    (def have (st/locate acc id))
                    (cond
                      (nil? have)
                      (let [a2 (-> acc
                                   (st/update-ws (or tag (hidden-tag acc id) (acc :current)) |(ws/append $ id))
                                   (forget-hidden-from id))
                            f (if (dictionary? facts) facts)]
                        (if (and f (= :float (cl/classify (a2 :rules) f)))
                          (set-floating a2 id true)
                          a2))
                      (or (nil? tag) (= have tag)) acc
                      (-> acc
                          (st/update-ws have |(ws/remove $ id))
                          (st/update-ws tag |(ws/append $ id)))))
                  s1 ordered)
            # a remembered home of a window the OS no longer has at all is dropped (ids are reused)
            acc (if (empty? (get acc :hidden-from {}))
                  acc
                  (let [m (acc :hidden-from)]
                    (d/assoc acc {:hidden-from (table/to-struct (from-pairs (seq [k :keys m :when (first-seen k)] [k (m k)])))})))
            os (acc :os-focus)]
        # The OS focus may have been observed before this window set was (at
        # startup, or a snapshot adding the focused window). That observation
        # is still valid: adopt it, as :window-opened does.
        (if (and os (= (st/locate acc os) (acc :current)))
          (-> acc
              (st/update-ws (acc :current) |(ws/focus-id $ os))
              (d/assoc {:external-focus false}))
          acc)))))

(defn- window-dragged
  "The user moved or resized `id` (ADR 0008 addendum): in xmonad that floats the window. Only when
  the window really ended up somewhere else than where we put it -- pressing the title bar and
  letting go also ends a move loop, and must not float anything."
  [s id rect]
  (def tag (and (valid-id? id) (valid-rect? rect) (st/locate s id)))
  (cond
    (nil? tag) s
    (not= tag (s :current)) s
    (st/floating? s id) s
    (= rect ((st/placements s) id))
    (if (get-in s [:misfit id])
      (d/assoc s {:misfit (d/without (s :misfit) id)})
      s)
    (set-floating s id true)))

(defn- window-moved
  "-> [state effects]"
  [s id rect]
  (def p (st/placements s))
  (def model (if (and (valid-id? id) (valid-rect? rect)) (p id)))
  (cond
    (nil? model) [s []]
    (= rect model) [(d/assoc s {:misfit (d/without (get s :misfit {}) id)}) []]
    (let [entry (get-in s [:misfit id])
          n (if (and entry (= (entry :rect) model)) (entry :n) 0)]
      (if (>= n misfit-limit)
        [s []]
        [(d/assoc s {:misfit (d/assoc (get s :misfit {})
                                      {id {:rect model :n (+ n 1)}})})
         [[:place id model]]]))))

# ---- commands ----------------------------------------------------------

(defn- next-layout [w]
  (def ls layout/layouts)
  (def i (or (index-of (w :layout) ls) -1))
  (ws/set-layout w (ls (mod (+ i 1) (length ls)))))

# commands that only move focus or change layout parameters
(def- ws-commands
  {:focus-next ws/focus-next
   :focus-prev ws/focus-prev
   :focus-master ws/focus-master
   :inc-master ws/inc-master
   :dec-master ws/dec-master
   :expand |(ws/resize-master $ ratio-step)
   :shrink |(ws/resize-master $ (- ratio-step))
   :next-layout next-layout})

# commands that reorder windows: need a real focused window
(def- reorder-commands
  {:swap-next ws/swap-next
   :swap-prev ws/swap-prev
   :swap-master ws/swap-master
   :shift-master ws/shift-master})

(defn- toggle-float [s]
  (def id (st/focused s))
  (if (and id (actionable? s))
    (set-floating s id (not (st/floating? s id)))
    s))

(defn- reassert-focus
  "ADR 0009: one delayed retry of a :goto's focus. Only when the OS reports a
  different, ordinary managed window; never from an unmanaged window or a
  floating dialog; at most once (the pending note is consumed)."
  [s args]
  (def p (s :pending-focus))
  (def t (and p (p :target)))
  (def os (s :os-focus))
  (if (and (empty? args) t os
           (= (st/locate s t) (s :current))
           (not (external? s))
           (not (st/floating? s os))
           (not= os t))
    [(-> s (d/without :pending-focus) (st/update-current |(ws/focus-id $ t)))
     [[:focus t]]]
    [s []]))

# ---- ADR 0006 D-7: the OS focus must not stay on a parked window ---------------------------

(defn stray-id
  "The id the OS focus rests on, if it is a window we know on a workspace we are NOT looking at."
  [s]
  (def id (s :os-focus))
  (when (and id (valid-id? id))
    (def tag (st/locate s id))
    (when (and tag (not= tag (s :current))) id)))

(defn stray?  [s] (not (nil? (stray-id s))))

(defn- stray-effect
  "[:focus f] if the visible workspace has a window, [:focus-none] if it is empty. Never for a window we
  do not manage (a dialog, the start menu, a fullscreen window we dropped): nothing is stolen."
  [s]
  (when (stray? s)
    (if (empty? ((st/current-ws s) :ids))
      [:focus-none]
      (when-let [f (st/focused s)] [:focus f]))))

(def- reclaim-limit 3)

(defn- reclaim-focus
  "Internal command (never bound). Evaluates the state NOW, so the order in which focus-changed and
  window-closed arrived does not matter. At most `reclaim-limit` tries per window (then a notify)."
  [s args]
  (def os (stray-id s))
  (cond
    (not (empty? args)) [s []]
    (nil? os) [(if (s :reclaim-tries) (d/without s :reclaim-tries) s) []]
    (let [t (s :reclaim-tries)
          n (if (and t (= (t :id) os)) (t :n) 0)]
      (cond
        (> n reclaim-limit) [s []]
        (= n reclaim-limit) [(d/assoc s {:reclaim-tries {:id os :n (+ n 1)}}) [[:notify :reclaim-gave-up os]]]
        (let [s1 (d/assoc s {:reclaim-tries {:id os :n (+ n 1)}})
              own (= os (get-in s [:stray-own :id]))]
          (if (and (= (s :stray-mode) :follow) (not own))
            # the user chose a parked window: go to its workspace instead of pulling them back
            (let [tag (st/locate s os)]
              [(-> s1
                   (d/assoc {:current tag :external-focus false})
                   (st/update-ws tag |(ws/focus-id $ os)))
               [[:goto tag]]])        # derive-effects adds hide/show/place and the :focus itself
            (if-let [e (stray-effect s)]
              [s1 [(tuple ;e :reclaim)]]
              [s1 []])))))))

(def- focus-moving? {:focus-next true :focus-prev true :focus-master true})

(def command-args
  "Every command the core understands -> what argument it takes
  (:none | :tag | :layout). The keymap validates bindings against this."
  (struct
    ;(mapcat |[$ :none]
              [;(keys ws-commands) ;(keys reorder-commands) :close :refresh])
    :goto :tag :send :tag :set-layout :layout :toggle-float :none
    :reassert-focus :internal :reclaim-focus :internal))   # :internal = issued by the shell, never bound to a key

(defn- own-stray
  "ADR 0006 D-7 (4d/4e): the window that keeps the OS focus after OUR goto/send is our own side
  effect, not the user's choice: :follow must not react to it."
  [s]
  (if-let [id (s :os-focus)] (d/assoc s {:stray-own {:id id}}) s))

(defn- goto-tag [s tag]
  # :os-focus stays: the OS front window really is still the old one (an observation, ADR 0005)
  (-> s (d/assoc {:current tag :external-focus true}) own-stray))

(defn- send-focused
  "xmonad's `shift`: move the focused window to another workspace; the view
  stays where it is."
  [s tag]
  (def id (st/focused s))
  (if (and id (actionable? s) (valid-tag? s tag) (not= tag (s :current)))
    [(-> s
         (st/update-current |(ws/remove $ id))
         (st/update-ws tag |(ws/insert $ id))
         (d/assoc {:stray-own {:id id}}))
     [[:send id tag]]]
    [s []]))

(defn- explicit-focus [s]
  (if-let [f (st/focused s)] [[:focus f]] []))

# -> [state' explicit-effects]
(defn- command [s name args]
  (cond
    (ws-commands name)
    (let [s2 (st/update-current s (ws-commands name))]
      # an explicit focus command is the user asking for a :focus even while
      # focus is external (that is how they get back from a dialog)
      [s2 (if (focus-moving? name) (explicit-focus s2) [])])

    (reorder-commands name)
    [(if (actionable? s) (st/update-current s (reorder-commands name)) s) []]

    (= name :goto)
    (let [tag (get args 0)]
      (if (and (valid-tag? s tag) (not= tag (s :current)))
        (let [s2 (goto-tag s tag)
              f (st/focused s2)
              # remember what we want focused: a later :reassert-focus may
              # restore it if the OS/Jwno overrides us (ADR 0009 R-10)
              s3 (if f (d/assoc s2 {:pending-focus {:target f :tag tag}}) s2)]
          [s3 [[:goto tag] ;(explicit-focus s2)]])
        [s []]))

    (= name :toggle-float) [(toggle-float s) []]

    (= name :reassert-focus) (reassert-focus s args)

    (= name :reclaim-focus) (reclaim-focus s args)

    (= name :send) (send-focused s (get args 0))

    (= name :close)
    [s (if (actionable? s) [[:close (st/focused s)]] [])]

    (= name :set-layout)
    (let [l (get args 0)]
      [(if (index-of l layout/layouts)
         (st/update-current s |(ws/set-layout $ l))
         s)
       []])

    [s []]))

# ---- effects -----------------------------------------------------------

(defn- all-ids [s] (mapcat |((st/ws-of s $) :ids) (s :tags)))

(defn- id-set [ids] (from-pairs (map |[$ true] ids)))

(defn- hidden-ids
  "Windows on workspaces we are not looking at."
  [s]
  (def vis (id-set ((st/current-ws s) :ids)))
  (filter |(not (vis $)) (all-ids s)))

(defn- all-places [s]
  (def p (st/placements s))
  (map |[:place $ (p $)] (st/tiled-ids s (st/current-ws s))))

(defn- visibility-effects
  "ADR 0006 D-1/D-6. hide: left the visible workspace for another one, or appeared on one we are not
  looking at; show: every window that enters the visible workspace (also a new one: if it was parked
  and forgotten, the adapter brings it back; otherwise :show is a no-op). Windows that merely vanished
  from the model (closed, minimised, ghosts) get neither: they are not ours to hide."
  [old new]
  (def old-all (id-set (all-ids old)))
  (def old-vis (id-set ((st/current-ws old) :ids)))
  (def new-vis (id-set ((st/current-ws new) :ids)))
  (def hides
    (seq [tag :in (new :tags)
          :let [w (st/ws-of new tag)]
          id :in (w :ids)
          :when (and (not (new-vis id)) (or (old-vis id) (not (old-all id))))]
      [:hide id]))
  (def shows
    (seq [id :in ((st/current-ws new) :ids)
          :when (not (old-vis id))]     # ADR 0006 D-6: a window we forgot may still be parked
      [:show id]))
  [;hides ;shows])

(defn- derive-effects [old new silent?]
  (def old-p (st/placements old))
  (def new-w (st/current-ws new))
  (def new-p (st/placements new))
  (def effects @[;(visibility-effects old new)])
  (each id (st/tiled-ids new new-w)
    (unless (= (old-p id) (new-p id))
      (array/push effects [:place id (new-p id)])))
  (def f (st/focused new))
  (when (and f (not silent?) (not (external? new))
             (or (not= f (st/focused old))
                 (not= (old :current) (new :current))))
    (array/push effects [:focus f]))
  effects)

(def- effect-rank
  "goto/send/close first (in the order given), then hide, show, place, and focus last."
  {:hide 1 :show 2 :place 3 :focus 4 :focus-none 4})

(defn- order-effects
  [fx]
  (def fx (distinct fx))
  (tuple ;(seq [r :in [0 1 2 3 4]
                e :in fx
                :when (= r (get effect-rank (first e) 0))]
            e)))

# ---- entry point -------------------------------------------------------

(defn- tail [xs] (if (empty? xs) [] (slice xs 1)))

(defn- settle-pending
  "Drop the pending :goto focus when it is stale (ADR 0009). A silent
  observation of a different window does NOT drop it: that is exactly the
  override we want to repair."
  [old s kind args]
  (def p (s :pending-focus))
  (cond
    (nil? p) s
    (or (nil? (st/locate s (p :target)))
        (not= (s :current) (p :tag))
        (and (= kind :focus-changed) (= (get args 0) (p :target)))
        # a decision the core itself just took (new window, close) wins
        (and (index-of kind [:window-opened :window-seen :window-closed])
             (not= (st/focused old) (st/focused s))))
    (d/without s :pending-focus)
    s))

(defn- update* [s0 event]
  (def kind (get event 0))
  (def args (tail event))
  # any command other than :reassert-focus is a new intent: forget the pending one
  (def internal? (and (= kind :command) (index-of (get args 0) [:reassert-focus :reclaim-focus])))
  (def s (cond
           (and (= kind :command) (= (get args 0) :refresh)) (d/without s0 :pending-focus)   # R-8 recovery: keep the reclaim bookkeeping
           (and (= kind :command) (not internal?)) (-> s0 (d/without :pending-focus) (d/without :stray-own) (d/without :reclaim-tries))
           s0))
  (cond
    (and (= kind :command) (= (get args 0) :refresh))
    (let [s2 (d/without s :misfit)
          f (st/focused s2)]
      {:state s2
       :effects (tuple ;(map |[:hide $] (hidden-ids s2))
                       ;(map |[:show $] ((st/current-ws s2) :ids))
                       ;(all-places s2)
                       ;(if (and f (not (external? s2))) [[:focus f]] []))})

    (= kind :window-moved)
    (let [[s2 fx] (window-moved s (get args 0) (get args 1))]
      {:state s2 :effects (tuple ;fx)})

    (let [[s2 explicit silent?]
          (case kind
            :window-opened [(open-window s (get args 0) (get args 1)) [] false]
            :window-closed [(close-window s (get args 0)) [] false]
            :window-dragged [(window-dragged s (get args 0) (get args 1)) [] false]
            :window-seen [(window-seen s (get args 0) (get args 1) (get args 2)) [] false]
            :focus-changed [(focus-window s (get args 0)) [] true]
            :desktop-changed [(desktop-changed s (get args 0)) [] true]
            :screen-changed [(if (valid-rect? (get args 0))
                               (d/assoc s {:screen (args 0)})
                               s)
                             [] false]
            :windows-observed [(windows-observed s (get args 0)) [] true]
            :command (let [[s* fx] (command s (get args 0) (tail args))]
                       [s* fx false])
            [s [] false])]
      (let [s3a (settle-pending s s2 kind args)
            # the stray mark ends when the OS focus is observed somewhere else; the tries end with the stray
            s3b (if (and (s3a :stray-own) (= kind :focus-changed) (not= (get args 0) (get-in s3a [:stray-own :id])))
                  (d/without s3a :stray-own)
                  s3a)
            s3 (if (and (s3b :reclaim-tries) (not (stray? s3b)) (not= (get args 0) :reclaim-focus))
                 (d/without s3b :reclaim-tries)
                 s3b)
            fx [;explicit ;(derive-effects s s3 silent?)]
            # D-7: a state-changing, non-silent transition that leaves the OS focus on a parked window
            # corrects it, unless a focus effect is already there (the reclaim command makes its own)
            stray-fx (if (and (not silent?) (not= s s3) (not (= kind :command))
                              (not (find |(index-of (first $) [:focus :focus-none]) fx)))
                       (stray-effect s3))
            stray-fx2 (if (and (not silent?) (= kind :command) (not internal?) (not= s s3)
                               (not (find |(index-of (first $) [:focus :focus-none]) fx)))
                        (stray-effect s3))]
        {:state s3
         :effects (order-effects [;fx ;(if stray-fx [stray-fx] []) ;(if stray-fx2 [stray-fx2] [])])}))))

(defn update [s event]
  (if (indexed? event) (update* s event) {:state s :effects []}))
