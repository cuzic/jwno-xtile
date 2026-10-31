#!/usr/bin/env bash
# Stop / SubagentStop hook (ADR 0003): the turn may not end while the core
# test suite fails. Exit 2 blocks the stop and feeds stderr back to Claude.
# If we are already inside a forced continuation (stop_hook_active), let it
# end so an unfixable failure cannot loop forever.
set -u
input="$(cat)"
if printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(dirname "$0")/..}" || exit 0
[ -f test/run.janet ] || exit 0

mise_bin="$(command -v mise || echo "$HOME/.local/bin/mise")"
if ! out="$("$mise_bin" exec -- janet test/run.janet 2>&1)"; then
  {
    echo "Tests are failing; fix them before finishing (mise run test)."
    printf '%s\n' "$out" | grep -v '^ok ' | tail -40
  } >&2
  exit 2
fi
exit 0
