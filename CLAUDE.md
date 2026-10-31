# jwno-xtile

xmonad-style tiling for Jwno (Windows), MIT. Pure-Janet functional core + thin shell.

## Commands
- Test: `mise run test` (= `janet test/run.janet`). A change is not done until this passes; a Stop hook (`scripts/stop-check.sh`) enforces it.
- First time: `uv tool install meson && mise install` (mise builds janet from source).

## Rules
- `src/core/` is pure: no I/O, no Jwno/jw32/ffi, only `./` imports (enforced by `test/purity-test.janet`). Decisions about WM state live there; the shell only translates events and executes effects. See `docs/adr/0001`.
- Use `d/assoc` (src/core/data.janet), never `merge`, for state updates: `merge` returns a mutable table.
- xmonad behaviour must match xmonad's StackSet.hs; `test/xmonad-model.janet` is the independent reference.
- The GPL-3.0 `jwno-layout-tall` checkout was deliberately deleted (ADR 0002). Do not re-clone or copy it. Jwno itself (MIT) is at `~/jwno-xtile-ref/jwno`.
- Non-trivial design decisions: write an ADR first (`docs/adr/`), get it reviewed, then implement.
- Invariants are listed in `docs/INVARIANTS.md`; property tests must cover each one.
- Anything only verifiable on Windows must be labelled "unverified on Windows".
