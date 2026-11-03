# Using jwno-xtile

Everything here is implemented and tested against the fake Jwno of the unit tests and a real Jwno on hosted Windows; what is
not verified on a real desktop is marked **(unverified)**.

## Concepts (xmonad, in five lines)
- A workspace is an ordered list of windows: the **master** first, then the **stack**. Layouts: **Tall** (master left, stack
  right), **Wide** (master on top), **Full** (every window gets the whole area).
- Windows that are *floating* are left out of the layout but stay in their workspace (dialogs, tool windows, windows you
  dragged, maximised windows).
- Workspaces `1`..`9`. One is visible per monitor. A window of any other workspace is parked off-screen.
- `goto` (Alt+N) is xmonad's `greedyView`: if the workspace is shown on another monitor the two monitors swap.

## Default keys (`Alt`; change `"Alt"` to `"Win"` in the config for the Win key)
**Alt as the modifier overrides Windows' own Alt+Tab, Alt+Space (window menu; Alt+Space, M moves a window with the keyboard) and
the Alt menu accelerators of many apps (Alt+H help, Alt+E edit, ...), and Alt+Enter in consoles (unverified).** Use `"Win"` if
that matters to you.

| Key | Command | Meaning |
|---|---|---|
| Alt+J / Alt+K, Alt+Tab / Alt+Shift+Tab | `focus-next` / `focus-prev` | move the focus along the stack |
| Alt+M | `focus-master` | focus the master |
| Alt+Enter | `swap-master` | swap the focused window with the master |
| Alt+Shift+J / K | `swap-next` / `swap-prev` | move the focused window along the stack |
| Alt+H / Alt+L | `shrink` / `expand` | master width |
| Alt+, / Alt+. | `inc-master` / `dec-master` | number of master windows |
| Alt+Space | `next-layout` | Tall -> Wide -> Full |
| Alt+Shift+C | `close` | close the focused window |
| Alt+1..9 | `goto N` | show workspace N (greedyView) |
| Alt+Shift+1..9 | `send N` | send the focused window to workspace N (the view stays) |
| Alt+W / E / R | `focus-screen 0/1/2` | focus a monitor **(several monitors: unverified)** |
| Alt+Shift+W / E / R | `send-to-screen 0/1/2` | send the focused window to a monitor |
| Alt+N | `refresh` | re-place everything (use it if something looks wrong) |

Not bound by default (bind them yourself in the `:bindings` list, or call `jwno.exe --repl ... -x ":xtile :COMMAND ARGS"`):
`toggle-float` (float / unfloat the focused window), `view N` (move the focus to the monitor that shows N), `set-layout NAME`,
`shift-master`, `set-gap N`, `set-padding N`, `inc-gap`, `dec-gap`.

A command that destroys or reorders (`close`, `send`, `swap-*`) only acts on the window you are really looking at: if the
focus is on something the manager does not manage (a dialog, the Start menu) it does nothing instead of guessing.

## Options (`(adapter/install jwno/context w32/win32 {...})`)
| Option | Default | Meaning |
|---|---|---|
| `:bindings` / `:keymap` | none | key bindings (see `km/default-bindings`), the Jwno keymap to put them in |
| `:rules` | `[]` | `{:match {...} :action :tile/:float/:ignore}`: how a new window is treated (class, exe, title; ADR 0008) |
| `:tags` | `"1"`..`"9"` | workspace names |
| `:gap`, `:padding` | 0 | pixels between tiles / round the screen (ADR 0013) |
| `:poll-seconds` | 2 | how often the adapter compares what Windows shows with what it placed (minimise, maximise, ...) |
| `:stray-mode` | `:return` | what to do when the focus ends up on a window of a hidden workspace (taskbar, Alt-Tab): `:return` pulls it back to the visible workspace, `:follow` goes to that workspace |
| `:hide-taskbar-button` | false | take the taskbar button of a parked window away (ITaskbarList through Janet's FFI; verified on one Windows 11 PC, ADR 0011) |
| `:multi-monitor?` | false | one screen per monitor (ADR 0012) **(unverified on real multi-monitor hardware)**. Off: only the main monitor is managed and windows of other monitors are left alone |
| `:log` | none | `(fn [level msg])` for the adapter's log lines |
| `:suppress-focus?`, `:watch-moves?`, `:verify-placements?`, `:reassert?`, `:clock` | internal | switches used by the tests; leave them alone |

## What to expect
- **Workspaces are not Windows virtual desktops.** Only the *current* Windows virtual desktop is managed; switching desktops
  switches which windows the manager sees. After switching away and back, the windows of other workspaces are gathered on the
  current workspace (the assignment is not kept). Several virtual desktops together with `:hide-taskbar-button` are
  **unverified on a real PC**.
- **Full-screen windows and windows matched by an `:ignore` rule belong to no workspace**; `goto` leaves them where they are.
- **A window that keeps coming back** after being parked (some apps refuse to stay off-screen) becomes a float of the
  current workspace instead of being fought over.
- **A minimised window that you restore** returns to its own workspace, unless you activated it yourself (then it comes to the
  current workspace).
- **Floats do not follow a workspace to another monitor** (several monitors; unverified).
- **Parked windows stay in the taskbar and Windows' Alt-Tab** (unless `:hide-taskbar-button`; Alt-Tab always keeps them; with Alt as the modifier the manager's own Alt+Tab replaces Windows' one). Choosing one
  gets you pulled back to the visible workspace (or taken to its workspace with `:stray-mode :follow`).
- **The focus goes to a small invisible "sink" window** when the visible workspace is empty, so what you type goes nowhere
  (Jwno's own key bindings still work there). **(IME / screen readers: unverified)**
- **A window that does not fit** (apps have a minimum size) is re-placed up to three times, then left alone.
- **At start** the manager takes in the windows that already exist (maximised ones are re-maximised after being placed; windows outside the main monitor are left alone unless `:multi-monitor?`).
- If the manager stops, every parked window is brought back; if it was killed, the next start puts off-screen windows back.

## Troubleshooting
- Something is off-screen after a crash: start Jwno again (it recovers stray windows), or press Alt+N.
- A window will not tile: it is probably floating (dialogs and tool windows are): `toggle-float` it, or add a `:rules` entry.
- Logs: Jwno's `--log-file`; the adapter logs through the `:log` option.
