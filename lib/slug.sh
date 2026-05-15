#!/usr/bin/env bash
# lib/slug.sh — canonical-slug + worktree-basename derivation.
#
# Source from other scripts; do not execute directly. Functions print one
# line to stdout and return 0 on success, 1 on failure.

# agent_handoff_strip_worktree_suffix <basename>
#
# Removes a trailing worktree-suffix from a directory basename.
# Recognised: -worker, -worker<N>, -dev-preview, -preview, -wt, -wt<N>.
agent_handoff_strip_worktree_suffix() {
  local base="$1"
  base="${base%-dev-preview}"
  base="${base%-preview}"
  # -worker, -worker<digits>
  if [[ "$base" =~ ^(.*)-worker[0-9]*$ ]]; then
    base="${BASH_REMATCH[1]}"
  fi
  # -wt, -wt<digits>
  if [[ "$base" =~ ^(.*)-wt[0-9]*$ ]]; then
    base="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$base"
}

# agent_handoff_canonical_slug <absolute-worktree-path>
#
# Returns the canonical-slug used to key all worktrees of a project. See
# spec/storage-convention.md for the rule.
agent_handoff_canonical_slug() {
  local abs="$1"
  if [[ -z "$abs" ]]; then
    return 1
  fi
  local dir base canonical_base canonical_abs
  dir="$(dirname -- "$abs")"
  base="$(basename -- "$abs")"
  canonical_base="$(agent_handoff_strip_worktree_suffix "$base")"
  if [[ "$dir" == "/" ]]; then
    canonical_abs="/$canonical_base"
  else
    canonical_abs="$dir/$canonical_base"
  fi
  # Replace all '/' with '-', then strip leading '-'.
  local slug="${canonical_abs//\//-}"
  slug="${slug#-}"
  printf '%s' "$slug"
}

# agent_handoff_worktree_basename <absolute-worktree-path>
#
# Returns the basename (without suffix stripping). This is the "me" /
# "recipient" key used for the inbox directory.
agent_handoff_worktree_basename() {
  local abs="$1"
  if [[ -z "$abs" ]]; then
    return 1
  fi
  basename -- "$abs"
}

# agent_handoff_validate_basename <basename>
#
# Returns 0 if <basename> is safe to use as a path segment (worktree
# basename, recipient key). Returns 1 with an error to stderr otherwise.
# Rejects: empty, '.', '..', any '/', any backslash, leading '-', any
# byte outside printable ASCII (control chars, NUL).
#
# Use defensively before joining a basename into an inbox path, and at
# the writer side before accepting a `--to` value.
agent_handoff_validate_basename() {
  local b="${1:-}"
  if [[ -z "$b" ]]; then
    printf 'agent-handoff: empty basename rejected\n' >&2
    return 1
  fi
  if [[ "$b" == "." || "$b" == ".." ]]; then
    printf 'agent-handoff: basename %q rejected (path component)\n' "$b" >&2
    return 1
  fi
  if [[ "$b" == */* || "$b" == *\\* ]]; then
    printf 'agent-handoff: basename %q rejected (contains path separator)\n' "$b" >&2
    return 1
  fi
  if [[ "$b" == -* ]]; then
    printf 'agent-handoff: basename %q rejected (leading dash)\n' "$b" >&2
    return 1
  fi
  # Positive whitelist: letters, digits, '.', '_', '-'. No spaces, no
  # control chars, no shell/path metacharacters, locale-independent.
  if [[ ! "$b" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf 'agent-handoff: basename rejected (allowed: A-Za-z0-9._-)\n' >&2
    return 1
  fi
  return 0
}

# agent_handoff_resolve_root [explicit-root]
#
# Returns an absolute worktree root. Order of resolution:
#   1. argument, if non-empty and a directory.
#   2. $CLAUDE_PROJECT_DIR if set and a directory.
#   3. `git rev-parse --show-toplevel`.
# Returns 1 with no output if none can be resolved.
agent_handoff_resolve_root() {
  local explicit="${1:-}"
  if [[ -n "$explicit" && -d "$explicit" ]]; then
    ( cd "$explicit" && pwd -P )
    return 0
  fi
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "$CLAUDE_PROJECT_DIR" ]]; then
    ( cd "$CLAUDE_PROJECT_DIR" && pwd -P )
    return 0
  fi
  if root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s' "$root"
    return 0
  fi
  return 1
}
