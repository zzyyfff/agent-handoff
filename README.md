# agent-handoff

Worktree-scoped, cross-tool session handoffs for AI coding agents.

Write a structured handoff at the end of a session — decisions made,
work already done that should not be redone, assumptions about the
external world — and the next session in the same worktree (or a
sibling) starts up with that context already in hand. Works across
Claude Code and OpenAI Codex CLI by writing to a single, tool-agnostic
inbox location.

## Why

When you `/clear`, `/compact`, restart, or switch worktrees, the next
session loses live conversation context. Auto-summarisation preserves
*facts* but drops the *why* — the rationale behind decisions, the
failed approaches not to retry, the running processes that need
re-arming, the credentials assumed present in your keychain.

`agent-handoff` exists to make a clean break a deliberate act rather
than a loss.

## What makes it different

| feature                            | this | gstack `/context-save` | cli-continues | handoff-md |
| ---------------------------------- | :--: | :--------------------: | :-----------: | :--------: |
| worktree-local by default          |  ✓   |                        |               |            |
| line-by-line review pass           |  ✓   |                        |               |            |
| archive-on-read (`unread/`→`read/`) |  ✓  |                        |       ✓       |            |
| explicit "what NOT to do" section  |  ✓   |                        |               |            |
| writes shared by Claude Code + Codex CLI | ✓ |                       |       ✓       |            |
| optional gbrain semantic-search mirror | ✓ |                       |               |            |
| drift warning on receive           |  ✓   |                        |               |            |

The differentiators are the opinions: worktree-locality is the default
and broadcasting is opt-in; review is on by default and `--no-review`
is opt-out; the file format reserves a section specifically for
negative knowledge so it can't accidentally drop out of summarisation.

## How it fits together

```
┌──────────────────┐         ┌──────────────────┐
│ Claude Code      │         │ OpenAI Codex CLI │
│  /handoff skill  │         │  /handoff plugin │
└────────┬─────────┘         └─────────┬────────┘
         │                             │
         │  atomic write               │  atomic write
         ▼                             ▼
┌────────────────────────────────────────────────────┐
│ ~/.agent-handoffs/<canonical-slug>/<recipient>/    │
│   unread/                                          │
│     YYYYMMDDTHHMMSSZ-from-<sender>.md              │
│   read/                                            │
└────────┬─────────────────────────────┬─────────────┘
         │                             │
         │  SessionStart hook          │  SessionStart hook
         │  (Claude Code)              │  (Codex CLI)
         ▼                             ▼
┌──────────────────┐         ┌──────────────────┐
│ next Claude      │         │ next Codex       │
│ session in this  │         │ session in this  │
│ worktree         │         │ worktree         │
└──────────────────┘         └──────────────────┘
```

Storage is the contract. Either writer can produce a file either reader
will surface, keyed by recipient worktree. Cross-tool handoffs work in
both directions.

## Install

```bash
git clone https://github.com/zzyyfff/agent-handoff ~/Developer/tooling/agent-handoff
cd ~/Developer/tooling/agent-handoff

# Once, globally:
./bin/install-skill-globally        # Claude Code /handoff skill
./bin/install-codex-plugin          # Codex CLI /handoff plugin

# Per project (call from the agent-handoff repo dir or pass a path):
./bin/install-into-project ~/path/to/project
```

`install-into-project` wires the SessionStart hook for both tools into
the project's settings. It is idempotent — safe to re-run.

For belt-and-suspenders, paste the block from
`adapters/codex-cli/AGENTS-snippet.md` into your project's `AGENTS.md`
(or `~/.codex/AGENTS.md` globally). Claude Code does not read AGENTS.md
as of May 2026 — for it, add an equivalent block to `~/.claude/CLAUDE.md`.

## Use

In any session:

```
/handoff
/handoff --to assistant-worker
/handoff --topic auth-refactor
/handoff --no-review
```

Then `/clear` (or restart, or switch worktrees) without losing context.
The next session in the recipient worktree surfaces the handoff
automatically at session start, prints it, and moves the file to
`read/`.

See `examples/sample-handoff.md` for what a finished handoff looks like.

## Spec

The spec is the source of truth and tool-agnostic. New adapters
(Cursor, Cline, Aider, …) should target it directly.

- [spec/file-format.md](spec/file-format.md) — YAML frontmatter +
  markdown section contract.
- [spec/storage-convention.md](spec/storage-convention.md) — path
  rules, slug derivation, atomic-write discipline.
- [spec/review-pass.md](spec/review-pass.md) — what the writer's
  review step does and when it prompts the user.

## Repo layout

```
agent-handoff/
├── spec/                       # the contract
├── lib/                        # shared bash helpers (slug, inbox)
├── adapters/
│   ├── claude-code/            # /handoff skill + SessionStart hook
│   └── codex-cli/              # /handoff plugin + SessionStart hook
├── bin/                        # installer scripts
├── docs/
│   └── failure-modes.md
├── examples/
│   └── sample-handoff.md
└── tests/
    └── run-tests.sh            # 46 tests, no external deps
```

## Tests

```bash
./tests/run-tests.sh
shellcheck -S warning lib/*.sh adapters/*/hooks/*.sh bin/* tests/*.sh
```

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Designed for the convention of [zzyyfff/claude-toolkit](https://github.com/zzyyfff/claude-toolkit)
(the canonical-slug rule, the SessionStart hook structure, the
`unread`/`read` inbox shape are all modelled on that toolkit's
`read-inbox.sh` + `claude-msg`).

Conceptual prior art:

- [yigitkonur/cli-continues](https://github.com/yigitkonur/cli-continues)
  — broader 16-tool session-parsing.
- [HERMESquant/oh-my-hermes](https://github.com/HERMESquant/oh-my-hermes)
  — `-w` worktree flag convention.
- gstack `/context-save` — different design point (cross-branch
  Conductor pickup), referenced for contrast.
