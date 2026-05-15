#!/usr/bin/env bash
# adapters/codex-cli/commands/handoff.sh
#
# Codex CLI's /handoff command. Emits the handoff procedure to stdout so
# the Codex agent follows the same steps as the Claude Code skill. The
# procedure itself is single-sourced in
# adapters/claude-code/skill/SKILL.md.
#
# Codex sets the working directory to the project root before invoking
# plugin commands and surfaces stdout into the agent's context.

set -euo pipefail

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

cat <<EOF
Run the handoff procedure documented in:

  $repo_root/adapters/claude-code/skill/SKILL.md

Use this repo's shared helpers:

  source $repo_root/lib/slug.sh
  source $repo_root/lib/inbox.sh

The storage path and file format are the same for both tools. After you
write the file with agent_handoff_atomic_write, do NOT read the inbox
yourself — the SessionStart hook handles surfacing in the next session.

Notes for Codex specifically:
- Use Codex's interactive prompt mechanism in place of AskUserQuestion
  during the review pass.
- Set frontmatter session_tool: codex-cli.
- Pass session_id if Codex exposes one via env (e.g. CODEX_SESSION_ID).
EOF

# Emit the canonical procedure verbatim so the agent has it inline.
if [[ -r "$repo_root/adapters/claude-code/skill/SKILL.md" ]]; then
  printf '\n--- PROCEDURE ---\n\n'
  cat "$repo_root/adapters/claude-code/skill/SKILL.md"
fi
