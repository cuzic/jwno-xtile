# Design: Functional Core, Imperative Shell

## Rule

Everything that decides *what should happen* lives in `src/core/` as pure
functions over immutable data. The shell (`src/shell/`, not written yet) only
(1) turns Jwno/OS notifications into events and (2) executes effects.
**The shell contains no branching on WM state.** If a shell function needs an
`if` about windows/workspaces/layout, that logic belongs in the core.

    Jwno hook ──► event (data) ──► core/update ──► {:state :effects} ──► shell executes effects
                                       ▲                 │
                                       └──── state ◄─────┘   (shell just stores it)

## Core API (the whole contract)

    (update state event) -> {:state state' :effects [effect ...]}

Events: `[:window-opened id &opt tag]` `[:window-seen id facts &opt tag]` `[:window-closed id]`
`[:focus-changed id-or-nil]` `[:desktop-changed tag]` `[:screen-changed rect]`
`[:window-moved id observed-rect]` `[:windows-observed [[id tag]...]]`
`[:command name & args]` (incl. `:refresh`)

Effects: `[:place id rect]` `[:focus id]` `[:close id]` `[:goto tag]`
`[:send id tag]`

Window ids are opaque to the core (the shell uses hwnd numbers). Rects are
`{:x :y :w :h}` in integer pixels.

## Decisions

- **Core outputs rects, not Jwno Frame operations.** Frame splitting is Jwno
  bookkeeping; keeping it out of the core keeps the core free of Jwno's
  semantics. OPEN: whether the shell applies rects via `window :transform`
  directly or reconciles a frame tree (needs a spike on Windows; see Risks).
- **Effects are derived by diffing** old and new state (`derive-effects`), so
  transitions never mention rendering and cannot forget to re-tile.
- **Observation principle (ADR 0005):** `:focus-changed` / `:desktop-changed`
  report what the OS already did; they update the model but never emit
  `:focus`. `:external-focus` is cleared only by observations; `:current`
  changes only on `:desktop-changed` or `:goto`.
- **xmonad semantics** match StackSet.hs exactly (ADR 0007), verified by a
  differential test against `test/xmonad-model.janet`.
- **Layouts** are `(arrange name params screen ids) -> [[id rect]...]`; Wide is
  Tall on transposed axes.
- Janet structs cannot hold `nil`; "no focus" = absent key (see `set-focus`).
  `merge` returns a mutable table, so use `data/assoc` (invariant I0).
  The property tests found both.

## Test strategy

1. Unit tests per core module (`test/*-test.janet`), exact expected values.
2. Event-level tests on `update` including the exact effect lists.
3. Property tests (`test/property-test.janet`): random event sequences, after
   every step assert — no window on two workspaces, focus valid, tiling covers
   the screen exactly with no overlap, `:place` effects match the model, and
   a mirror driven only by effects never drifts from the model.
4. Shell is tested against a fake `Jwno` context (record the effects it
   receives) — only mapping code, so the test is small.

Run: `mise run test`. Invariants: `docs/INVARIANTS.md`. Decisions: `docs/adr/`.

## Not done yet (ordered)

1. Gaps/padding, `Full` raising the focused window (shell detail).
2. (done, ADR 0008) classify + floating + `:toggle-float`.
4. Multi-monitor (screens list; per-screen current workspace).
5. Keymap as data (key string → `[:command ...]`), validated in tests.
6. Shell: hooks → events, effects → Jwno/VirtualDesktopAccessor calls.

## Risks to spike on Windows

- Does `window :transform` on every managed window fight with Jwno's own
  retile (monitor change, DPI)? Fallback: one Jwno frame per window, core
  rects pushed in via `frame :transform`.
- Virtual desktop ↔ workspace tag mapping and how a desktop switch made by the
  user (not by us) is observed (`:virtual-desktop-changed` hook exists).
- Focus lag (Firefox) seen by jwno-layout-tall: `GetForegroundWindow` as the
  source for `:focus-changed` events.
- No GPL code is copied; see ADR 0002 (reference checkouts live outside the repo).
