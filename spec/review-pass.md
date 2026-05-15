# Review pass

A differentiator of `agent-handoff` vs. other "save context" tools: after
drafting, the agent walks the handoff section by section and decides per
item whether it's worth including. The user gets pulled in only when the
judgement is genuinely uncertain *and* the item is bulky enough to matter.

## Why

A "dump everything" handoff is almost as useless as no handoff. The next
session has to re-read and re-judge what was real signal. The review pass
forces the writing session — which still has full context — to do that
work once, on behalf of the future session.

## Triggers

After the draft is written to a tmp file, the agent considers each section
in order. For each item within a section, classify on two axes:

| axis        | values                                            |
| ----------- | ------------------------------------------------- |
| confidence  | `high` / `low`                                    |
| bloat       | `low` / `high` (rough proxy: > 200 chars = high)  |

The action depends on the combination:

| confidence | bloat | action                                                |
| ---------- | ----- | ----------------------------------------------------- |
| high       | low   | keep silently                                         |
| high       | high  | keep silently                                         |
| low        | low   | keep silently — the cost of a wrong include is small  |
| low        | high  | **prompt the user** with include / skip / edit        |

The asymmetry is intentional: the user is interrupted only when both
correctness is in doubt *and* the item would significantly enlarge the
handoff.

## Prompt form

When prompting, the agent shows:

- The section name.
- A short summary of the item (one sentence at most).
- The first 400 characters of the item, followed by `…` if truncated.
- Options: `include` / `skip` / `edit`.

If the user picks `edit`, the agent asks what to change and applies it
in-place to the draft.

## Order of operations

1. Draft full handoff to tmp file with all gathered material.
2. Run review pass; collect user decisions.
3. Apply edits to tmp file.
4. Re-render frontmatter (any structural changes update field values).
5. Atomic write to final `unread/` path.

The user never sees a half-reviewed file on disk. The tmp file is removed
after the final rename, even on review-pass abort.

## Sections that always prompt

Some sections are inherently judgement-heavy and always trigger a single
prompt regardless of bloat:

- `## What NOT to do on resume` — negative knowledge is exactly the kind
  of content that gets dropped accidentally. The agent should ask: "Is
  there anything from this session that the next session should be told
  *not* to redo?" even if it has a tentative answer.
- `## Open follow-ups` — easy to leak in-progress thoughts here; one
  prompt confirms which items are real follow-ups vs. side-channel noise.

## Skip mode

A `--no-review` flag on the writing skill bypasses the entire review pass
and writes the draft as-is. Useful for scripted handoffs (e.g. CI emits
a handoff at the end of a job) where there is no user to prompt.
