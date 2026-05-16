# Codex CLI adapter

Three pieces:

- **Plugin manifest** at `plugin.toml` — declares the `/handoff`
  command and the SessionStart hook for OpenAI Codex CLI.
- **Hook** at `hooks/surface-handoffs.sh` — surfaces unread handoffs on
  session start; mirrors `agent_handoff_surface_all` to stderr (which
  Codex relays into the session context).
- **Command** at `commands/handoff.sh` — backs the `/handoff` slash
  command. Emits the canonical procedure (single-sourced from the
  Claude Code skill) so the Codex agent follows the same steps.
- **AGENTS snippet** at `AGENTS-snippet.md` — copy into `~/.codex/AGENTS.md`
  for belt-and-suspenders coverage.

## Install

From the repo root:

```bash
./bin/install
```

That single command symlinks this directory into
`~/.codex/plugins/agent-handoff/`, wires the SessionStart hook into
`~/.codex/hooks.json` (user-global; loads unconditionally for every
project), and does the same for the Claude Code adapter. See the
[root README](../../README.md). Idempotent.

## What gets wired into `~/.codex/hooks.json`

The installer appends an entry like the following to
`.hooks.SessionStart[]`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {"type": "command", "command": "/abs/path/to/adapters/codex-cli/hooks/surface-handoffs.sh"}
        ]
      }
    ]
  }
}
```

This is the same matcher-group + inner-hooks shape Claude Code uses.
The installer also strips any pre-fix top-level `SessionStart` key
(an old shape Codex silently ignored). Re-running `bin/install` does
not duplicate the entry.

## Where this differs from the Claude Code adapter

- Codex hooks read JSON on stdin and may write JSON on stdout; our hook
  drains stdin and writes the surface text to stderr, exiting 0 so
  Codex applies no overrides.
- The slash command is implemented as a script (Codex plugin
  convention) rather than a SKILL.md (Claude Code convention). Both
  point at the same procedure.
- Codex respects `AGENTS.md` natively; the Claude Code side gets the
  same guidance via the global `~/.claude/CLAUDE.md` (Claude Code does
  not read `AGENTS.md` as of May 2026 per upstream issue #6235).

## Cross-tool guarantee

A handoff written by Claude Code is surfaced by the Codex hook on the
next Codex session start in the same recipient worktree, and vice
versa. Both adapters read and write to `~/.agent-handoffs/` using the
same `lib/inbox.sh` and `lib/slug.sh` helpers.
