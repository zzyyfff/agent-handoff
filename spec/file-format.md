# Handoff file format

A handoff is a UTF-8 markdown file with YAML frontmatter. It is designed to
be readable by humans and parseable by tools, with no fields specific to any
one agent tool in required positions.

## Filename

```
<YYYYMMDD>T<HHMMSS>Z-from-<sender-basename>[-<topic-slug>][-<hex>].md
```

- Timestamps are ISO-8601 UTC, no separators in the date/time portions so
  the filename sorts chronologically by lexical order.
- `<sender-basename>` is `basename(git rev-parse --show-toplevel)` of the
  writing worktree.
- `<topic-slug>` is optional; when present it must be `[a-z0-9-]+`.
- `<hex>` is an optional uniqueness suffix (5 hex characters) appended
  by the writer's atomic-write helper when the otherwise-collision-free
  name (timestamp + sender + topic, all second-precise) is already in
  use in the destination directory. Reading code MUST NOT rely on the
  suffix's presence or absence; it exists only to make two same-second
  writes from the same sender/topic deterministic instead of one
  silently overwriting the other.

## Frontmatter

```yaml
---
name: <one-line title>
description: <one-line summary, surfaces in inbox banners>
from: <sender-worktree-basename>
to: <recipient-worktree-basename>
created: <ISO-8601-Z>
received_at: <ISO-8601-Z, written by receiver hook on archive; absent = unread>
branch: <git branch at write time>
head: <git short SHA at write time>
dirty_files_count: <integer>
session_tool: <"claude-code" | "codex-cli" | other>
session_id: <tool-specific session UUID, optional>
gbrain_page_slug: <slug if mirrored, optional>
topic: <topic-slug, optional, mirrors filename fragment>
---
```

Required: `name`, `description`, `from`, `to`, `created`, `branch`, `head`,
`dirty_files_count`, `session_tool`.

Optional: `received_at`, `session_id`, `gbrain_page_slug`, `topic`.

### Status semantics

There is no `status` field. Read-state is encoded by location:

- File in `unread/` ⇒ unread.
- File in `read/` with `received_at` set ⇒ read.
- File in `read/` without `received_at` ⇒ legacy or hand-moved; treat as
  read but without a known timestamp.

`received_at` is monotonic: a receiver hook only ever sets it, never clears
or rewrites it. This means partial gbrain outages reconcile cleanly: scan
`read/`, find files whose `gbrain_page_slug` is set but whose gbrain page
lacks the `received_at` tag, and backfill.

## Body

The body uses an opinionated section order. Sections may be omitted when
empty.

```markdown
# Handoff — <title>

## Status as of <date>
What's verified, what's in-flight, current working hypothesis.

## Immediate next action
The concrete first step the receiving session should take. One paragraph
or a short numbered list.

## Decisions made (with evidence)
Each decision tagged with file:line, a test result, or an external source.
The "why" lives here, not just the "what".

## Recently verified / completed — DO NOT REDO
Specific work already done. Prevents the next session from re-running the
same investigation or re-trying the same failed approach.

## Open follow-ups
Numbered list. Each: what, why it matters, what's blocking.

## Assumptions / world-model snapshot
External state this handoff depends on: file paths that exist, API
contracts, running processes, environment variables, credentials in
keychain, daemons expected up.

## Verification commands
Two to five concrete commands to confirm world-state matches before
trusting the handoff.

## Files touched this session
Path list for fast re-context.

## What NOT to do on resume
Explicit don'ts. Negative knowledge — the hard-won "we tried this and it
didn't work" content.

## Reader instruction
A short note to the receiving agent. The receiving tool's SessionStart
hook moves the file to `read/` automatically; this section is a
belt-and-suspenders reminder for cases where the hook is bypassed.
```

## Validation

A handoff is well-formed iff:

1. Filename matches the pattern above.
2. Frontmatter parses as YAML.
3. All required frontmatter fields are present and non-empty.
4. The body contains at least the `## Immediate next action` section.

Receiver hooks should surface malformed handoffs verbatim with a warning,
rather than dropping them silently.
