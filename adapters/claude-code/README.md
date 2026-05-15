# Claude Code adapter

Two pieces:

- **Skill** at `skill/SKILL.md` — provides `/handoff`. Installed globally
  by symlinking into `~/.claude/skills/handoff/`.
- **Hook** at `hooks/surface-handoffs.sh` — surfaces unread handoffs on
  SessionStart and archives them. Installed per-project by wiring into
  `.claude/settings.json`.

## Install the skill (one-time, global)

```bash
./bin/install-skill-globally
```

This symlinks `adapters/claude-code/skill/` to `~/.claude/skills/handoff/`.

## Wire the hook into a project

```bash
./bin/install-into-project /path/to/project
```

This appends an entry like the following to the project's
`.claude/settings.json` SessionStart array (creating the file if needed):

```json
{
  "hooks": {
    "SessionStart": [
      {"type": "command", "command": "/abs/path/to/adapters/claude-code/hooks/surface-handoffs.sh"}
    ]
  }
}
```

The hook is idempotent: running the installer twice does not duplicate
the entry.

## How they work together

1. In the writing session, `/handoff` runs the skill, which writes a
   markdown file to `~/.agent-handoffs/<slug>/<recipient>/unread/`.
2. On the next session start in the recipient worktree, the SessionStart
   hook reads any unread files, prints them, stamps `received_at`, and
   moves them to `read/`.

The skill never reads the inbox; the hook never writes to `unread/`.
