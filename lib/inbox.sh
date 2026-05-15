#!/usr/bin/env bash
# lib/inbox.sh — shared list/archive/path-resolve helpers.
#
# Source after lib/slug.sh.

# agent_handoff_root
#
# Returns the storage root, honouring AGENT_HANDOFF_ROOT for tests.
agent_handoff_root() {
  printf '%s' "${AGENT_HANDOFF_ROOT:-$HOME/.agent-handoffs}"
}

# agent_handoff_inbox_dir <canonical-slug> <recipient-basename> <unread|read>
agent_handoff_inbox_dir() {
  local slug="$1" recipient="$2" bucket="$3"
  printf '%s/%s/%s/%s' "$(agent_handoff_root)" "$slug" "$recipient" "$bucket"
}

# agent_handoff_ensure_inbox <canonical-slug> <recipient-basename>
#
# Creates unread/ and read/ for the given recipient. Mode 0700.
agent_handoff_ensure_inbox() {
  local slug="$1" recipient="$2"
  local base
  base="$(agent_handoff_root)/$slug/$recipient"
  umask 077
  mkdir -p -- "$base/unread" "$base/read"
}

# agent_handoff_iso_now
#
# Emits an ISO-8601 UTC timestamp suitable for `created` / `received_at`.
agent_handoff_iso_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# agent_handoff_timestamp_compact
#
# Emits the filename-friendly form of the current time: YYYYMMDDTHHMMSSZ.
agent_handoff_timestamp_compact() {
  date -u +%Y%m%dT%H%M%SZ
}

# agent_handoff_filename <sender-basename> [topic-slug]
#
# Returns the file basename only (caller joins with the inbox path).
agent_handoff_filename() {
  local sender="$1" topic="${2:-}"
  local ts
  ts="$(agent_handoff_timestamp_compact)"
  if [[ -n "$topic" ]]; then
    printf '%s-from-%s-%s.md' "$ts" "$sender" "$topic"
  else
    printf '%s-from-%s.md' "$ts" "$sender"
  fi
}

# agent_handoff_atomic_write <destination> < stdin
#
# Reads stdin, writes to a .tmp- sibling in the same directory, then
# renames. Mode 0600.
agent_handoff_atomic_write() {
  local dest="$1"
  local dir base tmp
  dir="$(dirname -- "$dest")"
  base="$(basename -- "$dest")"
  tmp="$dir/.tmp-$$-$(date +%s)-$RANDOM-$base"
  umask 077
  cat > "$tmp"
  mv -- "$tmp" "$dest"
}

# agent_handoff_read_frontmatter_field <file> <field>
#
# Extracts a single scalar YAML field from the frontmatter block. Prints
# the value (un-quoted) to stdout. Returns 1 if not found.
agent_handoff_read_frontmatter_field() {
  local file="$1" field="$2"
  awk -v field="$field" '
    BEGIN { in_fm = 0; found = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { exit }
    in_fm {
      # match "field: value", trimming whitespace
      if (match($0, "^[[:space:]]*" field "[[:space:]]*:[[:space:]]*")) {
        value = substr($0, RSTART + RLENGTH)
        # strip optional surrounding quotes
        sub(/^"/, "", value); sub(/"$/, "", value)
        sub(/^'\''/, "", value); sub(/'\''$/, "", value)
        # trim trailing whitespace
        sub(/[[:space:]]+$/, "", value)
        print value
        found = 1
        exit
      }
    }
    END { if (!found) exit 1 }
  ' "$file"
}

# agent_handoff_stamp_received_at <file> <iso-timestamp>
#
# Atomically updates the file: if `received_at` is present in the
# frontmatter, replace its value; otherwise insert the field just before
# the closing `---`. Uses tmp-then-rename.
agent_handoff_stamp_received_at() {
  local file="$1" ts="$2"
  local dir tmp
  dir="$(dirname -- "$file")"
  tmp="$dir/.tmp-stamp-$$-$RANDOM"
  umask 077
  awk -v ts="$ts" '
    BEGIN { in_fm = 0; fm_done = 0; inserted = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; print; next }
    in_fm && !fm_done && /^---[[:space:]]*$/ {
      if (!inserted) { print "received_at: " ts; inserted = 1 }
      fm_done = 1; in_fm = 0; print; next
    }
    in_fm && /^[[:space:]]*received_at[[:space:]]*:/ {
      print "received_at: " ts
      inserted = 1
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv -- "$tmp" "$file"
}

# agent_handoff_list_unread <inbox-unread-dir>
#
# Prints unread *.md files (lexically sorted, skipping dotfiles), one per
# line. Empty output (and exit 0) if directory does not exist or is empty.
agent_handoff_list_unread() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    return 0
  fi
  local f
  shopt -s nullglob
  for f in "$dir"/*.md; do
    [[ "$(basename -- "$f")" == .* ]] && continue
    printf '%s\n' "$f"
  done | sort
  shopt -u nullglob
}

# agent_handoff_archive <file> <read-dir>
#
# Moves <file> into <read-dir>. Caller is responsible for stamping
# received_at first.
agent_handoff_archive() {
  local src="$1" read_dir="$2"
  mkdir -p -- "$read_dir"
  mv -- "$src" "$read_dir/$(basename -- "$src")"
}

# agent_handoff_print_body <file>
#
# Prints everything after the closing frontmatter '---' to stdout.
agent_handoff_print_body() {
  awk '
    BEGIN { in_fm = 0; past_fm = 0 }
    NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; next }
    in_fm && /^---[[:space:]]*$/ { in_fm = 0; past_fm = 1; next }
    past_fm { print }
  ' "$1"
}

# agent_handoff_surface_all <out-fd>
#
# Reads unread handoffs for the current worktree, surfaces them (banner +
# drift warnings + body) to file descriptor <out-fd>, stamps received_at,
# and archives. Exits cleanly with no output if nothing to do.
#
# Requires lib/slug.sh sourced.
agent_handoff_surface_all() {
  local out_fd="${1:-1}"
  local root me slug unread_dir read_dir
  root="$(agent_handoff_resolve_root || true)"
  if [[ -z "$root" ]]; then
    return 0
  fi
  me="$(agent_handoff_worktree_basename "$root")"
  slug="$(agent_handoff_canonical_slug "$root")"
  unread_dir="$(agent_handoff_inbox_dir "$slug" "$me" unread)"
  read_dir="$(agent_handoff_inbox_dir "$slug" "$me" read)"

  local files
  mapfile -t files < <(agent_handoff_list_unread "$unread_dir")
  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi

  local current_branch current_head now
  current_branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  current_head="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo '')"
  now="$(agent_handoff_iso_now)"

  {
    printf '\n=== agent-handoff: %d unread for %s ===\n' "${#files[@]}" "$me"
    local f name from created branch head_sha
    for f in "${files[@]}"; do
      name="$(agent_handoff_read_frontmatter_field "$f" name || basename -- "$f")"
      from="$(agent_handoff_read_frontmatter_field "$f" from || echo unknown)"
      created="$(agent_handoff_read_frontmatter_field "$f" created || echo unknown)"
      branch="$(agent_handoff_read_frontmatter_field "$f" branch || echo '')"
      head_sha="$(agent_handoff_read_frontmatter_field "$f" head || echo '')"

      printf '\n--- %s\n' "$name"
      printf 'from:    %s\n' "$from"
      printf 'created: %s\n' "$created"
      printf 'branch:  %s (handoff) | %s (current)\n' "${branch:-?}" "${current_branch:-?}"
      printf 'head:    %s (handoff) | %s (current)\n' "${head_sha:-?}" "${current_head:-?}"

      if [[ -n "$branch" && -n "$current_branch" && "$branch" != "$current_branch" ]]; then
        printf '!! DRIFT: branch differs — handoff was written on %s, you are on %s\n' "$branch" "$current_branch"
      fi
      if [[ -n "$head_sha" && -n "$current_head" && "$head_sha" != "$current_head" ]]; then
        printf '!! DRIFT: HEAD differs — handoff was written at %s, you are at %s\n' "$head_sha" "$current_head"
      fi
      printf '\n'
      agent_handoff_print_body "$f"

      agent_handoff_stamp_received_at "$f" "$now"
      agent_handoff_archive "$f" "$read_dir"
    done
    printf '\n=== %d handoff(s) archived to read/ ===\n\n' "${#files[@]}"
  } >&"$out_fd"
}
