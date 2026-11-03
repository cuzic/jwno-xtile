# Design: Functional Core, Imperative Shell

## Rule

Everything that decides *what should happen* lives in `src/core/` as pure
functions over immutable data. The shell (`src/shell/runtime.janet` plus the
Jwno adapter `src/jwno/`) only (1) turns Jwno/OS notifications into events and
(2) executes effects.
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

Also `[:window-dragged id rect]` and the internal commands `:reassert-focus` / `:reclaim-focus`
(never bound to a key).

Effects: `[:place id rect]` `[:focus id]` `[:focus id :reclaim]` `[:focus-none]` `[:close id]`
`[:goto tag]` `[:send id tag]` `[:hide id]` `[:show id]` `[:notify kind id]`
(order: goto/send/close, hide, show, place, focus).

Window ids are opaque to the core (the shell uses hwnd numbers). Rects are
`{:x :y :w :h}` in integer pixels.

## Decisions

- **Workspaces are groups inside the WM, not Windows virtual desktops** (ADR 0006). A window of a workspace we
  are not looking at is *parked* (moved to -32000,-32000, still a real, visible-flagged window; the adapter
  remembers where it was). `:hide` / `:show` are derived from the visible-workspace diff; `:show` goes to every
  window that enters the visible workspace, so a window the core had forgotten is brought back too. Only the
  current Windows virtual desktop is managed.
- **The OS focus must not rest on a parked window** (ADR 0006 D-7). Core's `stray-focus` looks at `:os-focus`
  (not at transitions): on a known window of a hidden workspace it asks for `[:focus f]`, or `[:focus-none]` when the
  visible workspace is empty. `:focus-none` is carried out by a small *sink window* made on Jwno's UI thread
  (`win32.janet`): it swallows keys and Alt+F4, and Jwno's own key bindings still work in front of it.
  The runtime schedules `:reclaim-focus` (at most 3 tries per window) when a focus change left the focus on a
  parked window.
- **Jwno manages only the focused window at start** (found on a real PC), so the adapter offers every other
  top-level window of the desktop to Jwno at start (`adopt-existing!`), re-maximising the maximised ones, and (unless `:multi-monitor?`) leaving windows of
  other monitors. See `docs/spike/2026-11-01-real-machine.md`.

- **Core outputs rects, not Jwno Frame operations.** Frame splitting is Jwno
  bookkeeping; keeping it out of the core keeps the core free of Jwno's
  semantics. Decided (ADR 0004, Accepted): the adapter applies rects with `window :transform` (pinned with
  `:swp-flags`, read back; a mismatch is reported to the core as `[:window-moved]`).
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
4. Shell is tested against a fake `Jwno` context (`test/shell-test.janet`, `test/adapter-test.janet`),
   including an adapter-level property test of P-1 (the visible workspace is on screen, the rest parked).
5. Contract tests on real Jwno (`spike/run-contract.ps1`, run by the `spike-jwno` workflow on hosted Windows
   Server 2022/2025) and a runner for a real PC (`spike/real/`).

Run: `mise run test`. Invariants: `docs/INVARIANTS.md`. Decisions: `docs/adr/`.

## Not done yet (ordered)

1. Multi-monitor stage 3 in the adapter: floats moving between monitors with their workspace (ADR 0012).
2. Verify on a real desktop: drag detection, the sink window (IME, Narrator, foreground lock), adopt-existing! on
   a busy desktop, `:sw-hide` (opt-in, not built).
3. Open review items: ADR 0006 / docs/references/jwno-ecosystem.md (J4: why `desktop-name-changed` is missed on a
   new virtual desktop).

## Risks to spike on Windows

- Real-hardware behaviour of everything marked "unverified on Windows" in the ADRs (the hosted runner is not a
  user's desktop).
- No GPL code is copied; see ADR 0002 (reference checkouts live outside the repo).
