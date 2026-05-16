# Claude Code adapter

Two pieces:

- **Skill** at `skill/SKILL.md` — provides `/handoff`. Symlinked into
  `~/.claude/skills/handoff/`.
- **Hook** at `hooks/surface-handoffs.sh` — surfaces unread handoffs on
  SessionStart and archives them. Wired into `~/.claude/settings.json`
  at the user level so it fires for every project automatically.

## Install

From the repo root:

```bash
./bin/install
```

That single command symlinks the skill, symlinks the Codex CLI plugin,
and wires both hooks at the user level. See the [root README](../../README.md)
for details. The installer is idempotent.

## What gets wired into `~/.claude/settings.json`

The installer appends an entry like the following to
`.hooks.SessionStart[]` (creating the file or key if needed):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {"type": "command", "command": "/abs/path/to/adapters/claude-code/hooks/surface-handoffs.sh"}
        ]
      }
    ]
  }
}
```

Each SessionStart entry is a matcher group with its own inner `hooks`
array — same shape as PreToolUse, PostToolUse, etc. A flat
`{type, command}` directly in the SessionStart array is rejected by
Claude Code at startup with `hooks: Expected array, but received
undefined`. The installer migrates pre-existing flat entries to the
correct wrapper.

Re-running `bin/install` does not duplicate the entry — the installer
surgically removes prior agent-handoff entries before re-adding.

## How they work together

1. In the writing session, `/handoff` runs the skill, which writes a
   markdown file to `~/.agent-handoffs/<slug>/<recipient>/unread/`.
2. On the next session start in the recipient worktree, the SessionStart
   hook reads any unread files, prints them, stamps `received_at`, and
   moves them to `read/`.

The skill never reads the inbox; the hook never writes to `unread/`.
