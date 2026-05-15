#!/usr/bin/env bash
# adapters/codex-cli/hooks/surface-handoffs.sh
#
# SessionStart hook for OpenAI Codex CLI. Codex passes hook context as
# JSON on stdin and expects JSON or no output on stdout. We write the
# surface text to stderr (which Codex relays as session output) and exit
# 0 to signal no override.

set -euo pipefail

# Drain stdin to avoid SIGPIPE on the parent if Codex sends JSON we
# don't consume.
if [[ ! -t 0 ]]; then
  cat > /dev/null
fi

hook_self="${BASH_SOURCE[0]}"
while [[ -L "$hook_self" ]]; do
  link_target="$(readlink "$hook_self")"
  if [[ "$link_target" = /* ]]; then
    hook_self="$link_target"
  else
    hook_self="$(dirname -- "$hook_self")/$link_target"
  fi
done
repo_root="$(cd "$(dirname -- "$hook_self")/../../.." && pwd -P)"

# shellcheck source=../../../lib/slug.sh
source "$repo_root/lib/slug.sh"
# shellcheck source=../../../lib/inbox.sh
source "$repo_root/lib/inbox.sh"

# Codex doesn't always cd into the project root; honour CODEX_PROJECT_DIR
# if set.
if [[ -n "${CODEX_PROJECT_DIR:-}" ]]; then
  cd "$CODEX_PROJECT_DIR" 2>/dev/null || true
fi

agent_handoff_surface_all 2
