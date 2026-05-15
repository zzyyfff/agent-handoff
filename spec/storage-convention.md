# Storage convention

All handoffs live under a single tool-agnostic root so that adapters for
different agent tools can interoperate.

## Root

```
~/.agent-handoffs/
```

Per-user, not per-project. Multiple repositories share the root; isolation
between them is enforced by the `<canonical-slug>` path component.

## Path shape

```
~/.agent-handoffs/<canonical-slug>/<recipient-worktree-basename>/
├── unread/
│   └── <YYYYMMDD>T<HHMMSS>Z-from-<sender-basename>[-<topic>].md
└── read/
    └── (archived after surfacing; same filename)
```

### `<canonical-slug>`

Derived from `git rev-parse --show-toplevel`:

1. Take the absolute path of the worktree root.
2. Strip a trailing worktree-suffix from the basename if one is present.
   Recognised suffixes (case-sensitive): `-worker`, `-worker[0-9]+`,
   `-dev-preview`, `-preview`, `-wt`, `-wt[0-9]+`.
3. Replace every `/` in the resulting absolute path with `-`.
4. Strip the leading `-`.

This is identical to the slug derivation used by the user's existing
`claude-toolkit` so a worktree and its siblings share one slug. Examples:

| worktree path                                       | canonical-slug                                      |
| --------------------------------------------------- | --------------------------------------------------- |
| `/Users/jonathan/Developer/personal/assistant`      | `Users-jonathan-Developer-personal-assistant`       |
| `/Users/jonathan/Developer/personal/assistant-worker` | `Users-jonathan-Developer-personal-assistant`     |
| `/Users/jonathan/Developer/personal/assistant-wt2`  | `Users-jonathan-Developer-personal-assistant`       |
| `/home/alice/work/billing-dev-preview`              | `home-alice-work-billing`                           |

### `<recipient-worktree-basename>`

The intended recipient's worktree basename — i.e., `basename(git rev-parse
--show-toplevel)` of the recipient, **before** suffix stripping.

A handoff `--to assistant-worker` written from `assistant` lands under:

```
~/.agent-handoffs/Users-jonathan-Developer-personal-assistant/assistant-worker/unread/
```

The sender's own basename appears only in the filename, not the path.

## Atomic write

Writers must:

1. Create the destination directory tree if it does not exist.
2. Write the file contents to a sibling tmp file:
   `unread/.tmp-<pid>-<epoch>-<rand>` in the same directory.
3. `rename(2)` the tmp file to the final name.

This guarantees the receiver hook never reads a half-written file. Tmp
files matching `.tmp-*` must be ignored by all readers.

## Archive

Receivers move files from `unread/` to `read/` after surfacing. The move
is itself a `rename(2)` within the same filesystem.

Before the move, the receiver hook stamps `received_at: <ISO-8601-Z>` into
the file's frontmatter, using the same write-tmp-then-rename discipline so
a concurrent reader never sees a partial edit.

## Ignored entries

Readers must skip:

- Anything not ending in `.md`.
- Files whose basename starts with `.` (covers tmp files and editor
  scratch).

## Permissions

The root and all subdirectories are created mode `0700`; files are
written `0600`. Handoff content may contain sensitive context (auth
flows, internal URLs, etc.); restrict to the owning user.
