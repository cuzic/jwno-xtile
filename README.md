# jwno-xtile

xmonad-style tiling for [Jwno](https://github.com/agent-kilo/jwno) on Windows.
Functional core (`src/core/`, pure Janet, fully tested) + a thin imperative
shell (planned). See `docs/DESIGN.md`.

    uv tool install meson   # build dependency of mise's janet plugin
    mise install            # janet 1.42.1 (+ ninja)
    mise run test

MIT licensed.
