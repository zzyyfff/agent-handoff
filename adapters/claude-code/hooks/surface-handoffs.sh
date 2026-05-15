#!/usr/bin/env bash
# adapters/claude-code/hooks/surface-handoffs.sh
#
# SessionStart hook for Claude Code. Thin shim around
# agent_handoff_surface_all; surfaces banner + body to stdout so Claude
# Code includes it in the session context.
#
# Install: add to the SessionStart array in a project's
# .claude/settings.json. See bin/install-into-project.

set -euo pipefail

# Resolve repo root through any symlink chain.
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

agent_handoff_surface_all 1
