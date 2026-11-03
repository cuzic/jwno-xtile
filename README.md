# jwno-xtile

xmonad-style tiling for [Jwno](https://github.com/agent-kilo/jwno) on Windows (MIT).

- Master/stack tiling (Tall, Wide, Full) that follows xmonad's `StackSet`, floats, workspaces, several monitors.
- A pure Janet **core** (`src/core/`, fully tested, no I/O) decides everything; a thin adapter (`src/jwno/`) turns Jwno's
  hooks into events and carries out the core's effects. See `docs/DESIGN.md` and the decisions in `docs/adr/`.
- Workspaces are groups inside the window manager, not Windows virtual desktops: a window of another workspace is moved
  off-screen ("parked"), never hidden, so it cannot be lost when the manager stops.

**Status**: developed and tested against hosted Windows runners and one Windows 11 PC. Several things are still *unverified on
real hardware* (several monitors, IME with the focus sink window, drag detection) - they are listed in the ADRs and in
`docs/spike/`. Use it as a preview, not as your only window manager.

## Use

1. Install [Jwno](https://github.com/agent-kilo/jwno) (0.9.16 was used) and clone this repository.
2. Copy `jwno-config.example.janet` to your Jwno config, set `--mod-path` to the clone (or copy `src/`), restart Jwno.
3. Keys, commands and options: [`docs/USAGE.md`](docs/USAGE.md).

## Develop

    uv tool install meson   # build dependency of mise's janet plugin
    mise install            # janet (+ ninja)
    mise run test           # unit, property and differential tests; a change is not done until this passes

Contract tests against a real Jwno run in GitHub Actions (`spike-jwno` workflow, hosted Windows Server 2022/2025) and on a
real PC through `spike/real/` (see `docs/spike/2026-11-01-real-machine.md`; the real-PC run needs care: it must never run on
your own desktop - `spike/contract-config.janet` has a guard).

Rules for contributors are in `CLAUDE.md`: the core stays pure, non-trivial decisions get an ADR first, and the GPL-3.0
`jwno-layout-tall` was deliberately never copied (ADR 0002).
