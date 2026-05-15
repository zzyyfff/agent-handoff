#!/usr/bin/env bash
# tests/run-tests.sh — pure-bash test harness for agent-handoff.
#
# Usage:   tests/run-tests.sh
# Exit:    0 on success, 1 on any failure.
#
# Each test is a function prefixed `test_`. The harness discovers and runs
# them in declaration order, prints PASS/FAIL with a short message, and
# tallies at the end.

set -uo pipefail

repo_root="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=../lib/slug.sh
source "$repo_root/lib/slug.sh"
# shellcheck source=../lib/inbox.sh
source "$repo_root/lib/inbox.sh"

pass=0
fail=0
failed_names=()

# Assertions fail-fast: they `exit 1` from the test subshell rather than
# `return 1` from just the assert helper, so a failed assertion mid-test
# is not masked by a passing assertion later in the same test.
assert_eq() {
  local actual="$1" expected="$2" msg="${3:-}"
  if [[ "$actual" != "$expected" ]]; then
    printf '   assert_eq failed: %s\n     expected: %q\n     actual:   %q\n' "$msg" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '   assert_contains failed: %s\n     needle: %q\n     in:     %q\n' "$msg" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_file_exists() {
  local f="$1"
  if [[ ! -e "$f" ]]; then
    printf '   assert_file_exists failed: %s\n' "$f" >&2
    exit 1
  fi
}

# Each test runs in a fresh subshell with its own tmp dir + AGENT_HANDOFF_ROOT.
run_test() {
  local name="$1"
  local tmp
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  if (
    export AGENT_HANDOFF_ROOT="$tmp/handoffs"
    export HOME="$tmp/home"
    mkdir -p "$HOME"
    set -uo pipefail
    "$name"
  ); then
    printf '  PASS  %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s\n' "$name"
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
  rm -rf "$tmp"
  trap - EXIT
}

###############################################################################
# slug derivation
###############################################################################

test_slug_plain() {
  local got
  got="$(agent_handoff_canonical_slug /Users/jonathan/Developer/personal/assistant)"
  assert_eq "$got" "Users-jonathan-Developer-personal-assistant" "plain worktree"
}

test_slug_worker_suffix() {
  local got
  got="$(agent_handoff_canonical_slug /Users/jonathan/Developer/personal/assistant-worker)"
  assert_eq "$got" "Users-jonathan-Developer-personal-assistant" "-worker suffix stripped"
}

test_slug_worker_numbered() {
  local got
  got="$(agent_handoff_canonical_slug /Users/jonathan/Developer/personal/assistant-worker2)"
  assert_eq "$got" "Users-jonathan-Developer-personal-assistant" "-worker2 stripped"
}

test_slug_dev_preview() {
  local got
  got="$(agent_handoff_canonical_slug /home/alice/work/billing-dev-preview)"
  assert_eq "$got" "home-alice-work-billing" "-dev-preview stripped"
}

test_slug_wt_suffix() {
  local got
  got="$(agent_handoff_canonical_slug /tmp/proj/app-wt3)"
  assert_eq "$got" "tmp-proj-app" "-wt3 stripped"
}

test_slug_no_match_left_alone() {
  local got
  got="$(agent_handoff_canonical_slug /tmp/proj/regular-name)"
  assert_eq "$got" "tmp-proj-regular-name" "non-suffix name unchanged"
}

test_basename_no_strip() {
  local got
  got="$(agent_handoff_worktree_basename /Users/jonathan/Developer/personal/assistant-worker)"
  assert_eq "$got" "assistant-worker" "basename preserves suffix"
}

###############################################################################
# inbox helpers
###############################################################################

test_inbox_dir_path() {
  local got
  got="$(agent_handoff_inbox_dir slug-x recipient-y unread)"
  assert_eq "$got" "$AGENT_HANDOFF_ROOT/slug-x/recipient-y/unread" "inbox dir composed"
}

test_ensure_inbox_creates_dirs() {
  agent_handoff_ensure_inbox slug-a recipient-b
  assert_file_exists "$AGENT_HANDOFF_ROOT/slug-a/recipient-b/unread"
  assert_file_exists "$AGENT_HANDOFF_ROOT/slug-a/recipient-b/read"
  local mode
  mode="$(stat -c %a "$AGENT_HANDOFF_ROOT/slug-a/recipient-b" 2>/dev/null || stat -f %Lp "$AGENT_HANDOFF_ROOT/slug-a/recipient-b")"
  assert_eq "$mode" "700" "inbox mode 0700"
}

test_iso_now_format() {
  local got
  got="$(agent_handoff_iso_now)"
  [[ "$got" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
    || { printf '   iso_now bad: %s\n' "$got" >&2; return 1; }
}

test_filename_with_topic() {
  local got
  # Stub date for deterministic output by overriding the function.
  agent_handoff_timestamp_compact() { printf '20260516T142300Z'; }
  got="$(agent_handoff_filename assistant my-topic)"
  unset -f agent_handoff_timestamp_compact
  assert_eq "$got" "20260516T142300Z-from-assistant-my-topic.md" "filename with topic"
}

test_filename_without_topic() {
  agent_handoff_timestamp_compact() { printf '20260516T142300Z'; }
  local got
  got="$(agent_handoff_filename assistant)"
  unset -f agent_handoff_timestamp_compact
  assert_eq "$got" "20260516T142300Z-from-assistant.md" "filename without topic"
}

test_atomic_write_creates_file() {
  agent_handoff_ensure_inbox slug-c recipient-d
  local dest="$AGENT_HANDOFF_ROOT/slug-c/recipient-d/unread/test.md"
  printf 'hello\n' | agent_handoff_atomic_write "$dest"
  assert_file_exists "$dest"
  local content
  content="$(cat "$dest")"
  assert_eq "$content" "hello" "content written"
  # No tmp file left behind
  local tmp_count
  tmp_count="$(find "$AGENT_HANDOFF_ROOT/slug-c/recipient-d/unread" -name '.tmp-*' | wc -l | tr -d ' ')"
  assert_eq "$tmp_count" "0" "no tmp file left"
}

###############################################################################
# frontmatter parsing
###############################################################################

write_sample_handoff() {
  local dest="$1"
  cat > "$dest" <<'EOF'
---
name: Test handoff
description: A test
from: sender
to: receiver
created: 2026-05-15T10:00:00Z
branch: main
head: abc1234
dirty_files_count: 0
session_tool: claude-code
---

# Handoff — Test

## Immediate next action
Just a test body.

## What NOT to do on resume
Don't re-test.
EOF
}

test_read_frontmatter_field_name() {
  local f="$AGENT_HANDOFF_ROOT/sample.md"
  mkdir -p "$AGENT_HANDOFF_ROOT"
  write_sample_handoff "$f"
  local got
  got="$(agent_handoff_read_frontmatter_field "$f" name)"
  assert_eq "$got" "Test handoff" "frontmatter name"
}

test_read_frontmatter_field_branch() {
  local f="$AGENT_HANDOFF_ROOT/sample.md"
  mkdir -p "$AGENT_HANDOFF_ROOT"
  write_sample_handoff "$f"
  local got
  got="$(agent_handoff_read_frontmatter_field "$f" branch)"
  assert_eq "$got" "main" "frontmatter branch"
}

test_read_frontmatter_field_missing() {
  local f="$AGENT_HANDOFF_ROOT/sample.md"
  mkdir -p "$AGENT_HANDOFF_ROOT"
  write_sample_handoff "$f"
  if agent_handoff_read_frontmatter_field "$f" nope >/dev/null 2>&1; then
    printf '   expected failure for missing field\n' >&2
    return 1
  fi
}

test_read_frontmatter_does_not_match_body() {
  # A line "name: ..." appearing in the body must not be returned.
  local f="$AGENT_HANDOFF_ROOT/sample.md"
  mkdir -p "$AGENT_HANDOFF_ROOT"
  cat > "$f" <<'EOF'
---
name: Real name
created: 2026-05-15T10:00:00Z
---

# Body
name: Fake name in body
EOF
  local got
  got="$(agent_handoff_read_frontmatter_field "$f" name)"
  assert_eq "$got" "Real name" "frontmatter parser stops at closing ---"
}

###############################################################################
# received_at stamping
###############################################################################

test_stamp_received_at_inserts() {
  local f="$AGENT_HANDOFF_ROOT/sample.md"
  mkdir -p "$AGENT_HANDOFF_ROOT"
  write_sample_handoff "$f"
  agent_handoff_stamp_received_at "$f" "2026-05-16T14:23:00Z"
  local got
  got="$(agent_handoff_read_frontmatter_field "$f" received_at)"
  assert_eq "$got" "2026-05-16T14:23:00Z" "received_at inserted"
  # Body must be intact
  local body
  body="$(agent_handoff_print_body "$f")"
  assert_contains "$body" "## Immediate next action" "body preserved"
}

test_stamp_received_at_replaces_existing() {
  local f="$AGENT_HANDOFF_ROOT/sample.md"
  mkdir -p "$AGENT_HANDOFF_ROOT"
  cat > "$f" <<'EOF'
---
name: Test
received_at: 2026-01-01T00:00:00Z
created: 2026-05-15T10:00:00Z
---

body
EOF
  agent_handoff_stamp_received_at "$f" "2026-05-16T14:23:00Z"
  local got
  got="$(agent_handoff_read_frontmatter_field "$f" received_at)"
  assert_eq "$got" "2026-05-16T14:23:00Z" "received_at replaced not duplicated"
  # Ensure it appears exactly once
  local count
  count="$(grep -c '^received_at:' "$f")"
  assert_eq "$count" "1" "received_at appears once"
}

###############################################################################
# list / archive
###############################################################################

test_list_unread_skips_dotfiles_and_non_md() {
  local dir="$AGENT_HANDOFF_ROOT/slug/r/unread"
  mkdir -p "$dir"
  touch "$dir/a.md" "$dir/.tmp-xyz" "$dir/notes.txt" "$dir/b.md"
  local listed
  listed="$(agent_handoff_list_unread "$dir" | tr '\n' '|')"
  assert_contains "$listed" "a.md" "a.md listed"
  assert_contains "$listed" "b.md" "b.md listed"
  if [[ "$listed" == *".tmp-xyz"* ]]; then
    printf '   tmp file should be skipped\n' >&2; return 1
  fi
  if [[ "$listed" == *"notes.txt"* ]]; then
    printf '   non-md should be skipped\n' >&2; return 1
  fi
}

test_list_unread_missing_dir() {
  local got
  got="$(agent_handoff_list_unread "$AGENT_HANDOFF_ROOT/does/not/exist")"
  assert_eq "$got" "" "missing dir => empty output, no error"
}

test_archive_moves_file() {
  agent_handoff_ensure_inbox slug-arch me
  local f="$AGENT_HANDOFF_ROOT/slug-arch/me/unread/x.md"
  write_sample_handoff "$f"
  local read_dir="$AGENT_HANDOFF_ROOT/slug-arch/me/read"
  agent_handoff_archive "$f" "$read_dir"
  if [[ -e "$f" ]]; then
    printf '   source should be gone\n' >&2; return 1
  fi
  assert_file_exists "$read_dir/x.md"
}

###############################################################################
# end-to-end: surface_all
###############################################################################

# To exercise agent_handoff_surface_all in isolation from a real git repo,
# we stub agent_handoff_resolve_root, agent_handoff_worktree_basename, and
# agent_handoff_canonical_slug after sourcing.

setup_fake_worktree() {
  local me="$1"
  # Bake the basename in so the overrides do not depend on a local
  # variable from a parent scope (which would be unset by the time
  # surface_all calls them and trip `set -u`).
  eval "agent_handoff_resolve_root() { printf '%s' \"\$AGENT_HANDOFF_ROOT/_fake/$me\"; }"
  eval "agent_handoff_worktree_basename() { printf '%s' '$me'; }"
  agent_handoff_canonical_slug() { printf '%s' "_fake"; }
  mkdir -p "$AGENT_HANDOFF_ROOT/_fake/$me"
}

test_surface_all_empty_silent() {
  setup_fake_worktree assistant
  local out
  out="$(agent_handoff_surface_all 1 2>&1)"
  assert_eq "$out" "" "no inbox => no output"
}

test_surface_all_prints_and_archives() {
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  local f="$AGENT_HANDOFF_ROOT/_fake/assistant/unread/20260516T100000Z-from-sender.md"
  write_sample_handoff "$f"
  local out
  out="$(agent_handoff_surface_all 1 2>&1)"
  assert_contains "$out" "Test handoff" "name printed"
  assert_contains "$out" "## Immediate next action" "body printed"
  assert_contains "$out" "1 UNTRUSTED handoff(s) for assistant" "header"
  # File moved
  if [[ -e "$f" ]]; then
    printf '   file should have been archived\n' >&2; return 1
  fi
  local archived="$AGENT_HANDOFF_ROOT/_fake/assistant/read/20260516T100000Z-from-sender.md"
  assert_file_exists "$archived"
  # received_at stamped
  local rcv
  rcv="$(agent_handoff_read_frontmatter_field "$archived" received_at)"
  if [[ -z "$rcv" ]]; then
    printf '   received_at not stamped\n' >&2; return 1
  fi
}

test_surface_all_isolation_other_recipient() {
  # File addressed to recipient-b should not surface for recipient-a.
  setup_fake_worktree recipient-a
  agent_handoff_ensure_inbox _fake recipient-b
  local f="$AGENT_HANDOFF_ROOT/_fake/recipient-b/unread/20260516T100000Z-from-sender.md"
  write_sample_handoff "$f"
  local out
  out="$(agent_handoff_surface_all 1 2>&1)"
  assert_eq "$out" "" "different recipient's inbox not surfaced"
  # File still present in recipient-b
  assert_file_exists "$f"
}

# A drift test needs a real git repo so resolve_root + branch detection work.
test_surface_all_drift_warning() {
  local repo="$AGENT_HANDOFF_ROOT/_realrepo"
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    git init -q -b main
    git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m initial
  )
  # Resolve via real git, but pin slug/basename via overrides for path stability.
  agent_handoff_resolve_root() { printf '%s' "$repo"; }
  agent_handoff_worktree_basename() { printf 'worktree-x'; }
  agent_handoff_canonical_slug() { printf '_realrepo'; }

  agent_handoff_ensure_inbox _realrepo worktree-x
  local f="$AGENT_HANDOFF_ROOT/_realrepo/worktree-x/unread/20260516T100000Z-from-sender.md"
  cat > "$f" <<'EOF'
---
name: Drift test
description: drift
from: sender
to: worktree-x
created: 2026-05-15T10:00:00Z
branch: feature/old
head: 0000000
dirty_files_count: 0
session_tool: claude-code
---

# Drift body
EOF
  local out
  out="$(agent_handoff_surface_all 1 2>&1)"
  assert_contains "$out" "DRIFT: branch differs" "branch drift warned"
  assert_contains "$out" "DRIFT: HEAD differs" "head drift warned"
}

###############################################################################
# validate_basename + adversarial inputs
###############################################################################

test_validate_basename_accepts_safe() {
  agent_handoff_validate_basename "assistant" 2>/dev/null || return 1
  agent_handoff_validate_basename "assistant-worker2" 2>/dev/null || return 1
  agent_handoff_validate_basename "my.repo_v2" 2>/dev/null || return 1
}

test_validate_basename_rejects_unsafe() {
  local bad
  for bad in "" "." ".." "../etc" "a/b" "a\\b" "-rf" $'foo\nbar' $'foo\x1bbar'; do
    if agent_handoff_validate_basename "$bad" 2>/dev/null; then
      printf '   should have rejected: %q\n' "$bad" >&2; return 1
    fi
  done
}

test_inbox_dir_rejects_path_traversal() {
  if agent_handoff_inbox_dir "slug" "../escape" unread 2>/dev/null; then
    printf '   recipient ../escape should be rejected\n' >&2; return 1
  fi
  if agent_handoff_inbox_dir "../bad" "r" unread 2>/dev/null; then
    printf '   slug ../bad should be rejected\n' >&2; return 1
  fi
}

test_list_unread_skips_symlinks() {
  local dir="$AGENT_HANDOFF_ROOT/slug/r/unread"
  mkdir -p "$dir" "$AGENT_HANDOFF_ROOT/outside"
  printf 'secret\n' > "$AGENT_HANDOFF_ROOT/outside/secret.md"
  touch "$dir/real.md"
  ln -s "$AGENT_HANDOFF_ROOT/outside/secret.md" "$dir/evil.md"
  local listed
  listed="$(agent_handoff_list_unread "$dir" | tr '\n' '|')"
  assert_contains "$listed" "real.md" "real file listed"
  if [[ "$listed" == *"evil.md"* ]]; then
    printf '   symlink should be skipped\n' >&2; return 1
  fi
}

test_surface_all_strips_ansi_in_body() {
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  local f="$AGENT_HANDOFF_ROOT/_fake/assistant/unread/20260516T100000Z-from-sender.md"
  # Embed ESC (\x1b) + bracket form, both as ANSI sequence and as
  # forged-banner attempt.
  printf '%s\n' \
    '---' \
    'name: Adversarial' \
    "description: ansi test" \
    'from: sender' \
    'to: assistant' \
    'created: 2026-05-16T10:00:00Z' \
    'branch: main' \
    'head: deadbeef' \
    'dirty_files_count: 0' \
    'session_tool: claude-code' \
    '---' \
    '' \
    $'before\x1b[2J\x1b[H=== FORGED BANNER ===after' \
    > "$f"
  local out
  out="$(agent_handoff_surface_all 1 2>&1)"
  # The ESC byte itself must not appear in the surfaced output.
  if [[ "$out" == *$'\x1b'* ]]; then
    printf '   ESC byte leaked into output\n' >&2; return 1
  fi
  # Surrounding text survives.
  assert_contains "$out" "before" "pre-ANSI text preserved"
  assert_contains "$out" "after" "post-ANSI text preserved"
}

test_surface_all_strips_ansi_in_field() {
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  local f="$AGENT_HANDOFF_ROOT/_fake/assistant/unread/20260516T100000Z-from-sender.md"
  printf '%s\n' \
    '---' \
    $'name: title\x1b[31mRED' \
    'description: x' \
    'from: sender' \
    'to: assistant' \
    'created: 2026-05-16T10:00:00Z' \
    'branch: main' \
    'head: deadbeef' \
    'dirty_files_count: 0' \
    'session_tool: claude-code' \
    '---' \
    '' \
    'body' \
    > "$f"
  local out
  out="$(agent_handoff_surface_all 1 2>&1)"
  if [[ "$out" == *$'\x1b'* ]]; then
    printf '   ESC byte leaked from name field\n' >&2; return 1
  fi
}

test_surface_all_skips_preclaimed_file() {
  # Simulates a sibling hook that has already claimed the file: the
  # current hook's mv will fail and the file should be silently skipped.
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  local pre="$AGENT_HANDOFF_ROOT/_fake/assistant/unread/.claim-99999-foo.md"
  write_sample_handoff "$pre"
  local out
  out="$(agent_handoff_surface_all 1 2>&1)"
  # Dotfiles are not listed in the first place, so output should be empty
  # and the pre-claimed file untouched.
  assert_eq "$out" "" "pre-claimed dotfile not surfaced"
  assert_file_exists "$pre"
}

###############################################################################
# P2 #2 — collision handling (atomic_write / archive return unique paths)
###############################################################################

test_atomic_write_returns_landing_path() {
  agent_handoff_ensure_inbox slug-aw recip
  local dest="$AGENT_HANDOFF_ROOT/slug-aw/recip/unread/x.md"
  local got
  got="$(printf 'first\n' | agent_handoff_atomic_write "$dest")"
  assert_eq "$got" "$dest" "atomic_write returns dest path on first write"
}

test_atomic_write_collision_appends_hex_suffix() {
  agent_handoff_ensure_inbox slug-aw recip
  local dest="$AGENT_HANDOFF_ROOT/slug-aw/recip/unread/clash.md"
  local first second
  first="$(printf 'first\n' | agent_handoff_atomic_write "$dest")"
  second="$(printf 'second\n' | agent_handoff_atomic_write "$dest")"
  assert_eq "$first" "$dest" "first write lands at exact dest"
  # Second must differ and must match clash-<5hex>.md.
  if [[ "$second" == "$dest" ]]; then
    printf '   second write should not equal first\n' >&2; exit 1
  fi
  if [[ ! "$second" =~ /clash-[0-9a-f]{5}\.md$ ]]; then
    printf '   expected /clash-XXXXX.md, got %s\n' "$second" >&2; exit 1
  fi
  # Both files exist and contents differ.
  assert_eq "$(cat "$first")" "first" "first content intact"
  assert_eq "$(cat "$second")" "second" "second content intact"
}

test_atomic_write_does_not_overwrite_via_helper() {
  # Direct collision against an existing non-handoff file should still
  # be honored (suffix appended, original untouched).
  agent_handoff_ensure_inbox slug-aw recip
  local dest="$AGENT_HANDOFF_ROOT/slug-aw/recip/unread/precious.md"
  printf 'do-not-clobber\n' > "$dest"
  local got
  got="$(printf 'newcomer\n' | agent_handoff_atomic_write "$dest")"
  assert_eq "$(cat "$dest")" "do-not-clobber" "original file untouched"
  assert_eq "$(cat "$got")" "newcomer" "newcomer landed at suffixed path"
}

test_atomic_write_directory_at_dest_treated_as_collision() {
  # A directory at the candidate path must NOT make `ln src dir/`
  # succeed by linking inside it (which would make the file invisible
  # to glob-based readers). safe_rename must skip it and use a suffix.
  agent_handoff_ensure_inbox slug-aw recip
  local dest="$AGENT_HANDOFF_ROOT/slug-aw/recip/unread/dirclash.md"
  mkdir -p "$dest"  # dest is now a directory
  local got
  got="$(printf 'content\n' | agent_handoff_atomic_write "$dest")"
  # The directory must still be a directory, not turned into a file.
  if [[ ! -d "$dest" ]]; then
    printf '   expected %s to remain a directory\n' "$dest" >&2; exit 1
  fi
  # The actual landing must be a suffixed file.
  if [[ "$got" == "$dest" ]]; then
    printf '   should not have landed at directory path\n' >&2; exit 1
  fi
  if [[ ! "$got" =~ /dirclash-[0-9a-f]{5}\.md$ ]]; then
    printf '   expected suffixed path, got %s\n' "$got" >&2; exit 1
  fi
  assert_eq "$(cat "$got")" "content" "content landed at suffixed path"
}

test_archive_collision_appends_hex_suffix() {
  agent_handoff_ensure_inbox slug-arch me
  local read_dir="$AGENT_HANDOFF_ROOT/slug-arch/me/read"
  mkdir -p "$read_dir"
  printf 'existing archived\n' > "$read_dir/dup.md"
  local src="$AGENT_HANDOFF_ROOT/slug-arch/me/unread/dup.md"
  write_sample_handoff "$src"
  local got
  got="$(agent_handoff_archive "$src" "$read_dir")"
  if [[ "$got" == "$read_dir/dup.md" ]]; then
    printf '   archive should not have overwritten existing dup.md\n' >&2; exit 1
  fi
  if [[ ! "$got" =~ /dup-[0-9a-f]{5}\.md$ ]]; then
    printf '   expected /dup-XXXXX.md, got %s\n' "$got" >&2; exit 1
  fi
  assert_eq "$(cat "$read_dir/dup.md")" "existing archived" "existing untouched"
}

###############################################################################
# P2 #3 — malformed handoffs surfaced verbatim with warning
###############################################################################

test_print_body_warns_and_dumps_when_frontmatter_unclosed() {
  local f="$AGENT_HANDOFF_ROOT/malformed.md"
  mkdir -p "$AGENT_HANDOFF_ROOT"
  cat > "$f" <<'EOF'
---
name: truncated
description: writer crashed mid-write
EOF
  local out
  out="$(agent_handoff_print_body "$f")"
  assert_contains "$out" "WARNING: malformed handoff" "warning surfaced"
  assert_contains "$out" "name: truncated" "raw frontmatter dumped"
  assert_contains "$out" "writer crashed mid-write" "raw body dumped"
}

test_print_body_warns_on_empty_file() {
  local f="$AGENT_HANDOFF_ROOT/empty.md"
  mkdir -p "$AGENT_HANDOFF_ROOT"
  : > "$f"
  local out
  out="$(agent_handoff_print_body "$f")"
  assert_contains "$out" "WARNING: malformed handoff" "warning surfaced on empty"
}

test_surface_all_surfaces_malformed_with_warning() {
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  local f="$AGENT_HANDOFF_ROOT/_fake/assistant/unread/20260516T100000Z-from-sender.md"
  cat > "$f" <<'EOF'
---
name: missing close
description: no closing dashes
EOF
  local out
  out="$(agent_handoff_surface_all 1 2>&1)"
  assert_contains "$out" "WARNING: malformed handoff" "warning shown via surface_all"
  assert_contains "$out" "name: missing close" "raw content shown via surface_all"
  if [[ -e "$f" ]]; then
    printf '   malformed file should still be archived after surfacing\n' >&2; exit 1
  fi
}

###############################################################################
# install-into-project (Codex JSON shape regression)
###############################################################################

# These tests exercise bin/install-into-project against a fresh fake
# project dir. They require jq (same as the script itself).

test_install_into_project_writes_correct_codex_format() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  local project="$AGENT_HANDOFF_ROOT/_proj"
  mkdir -p "$project"
  "$repo_root/bin/install-into-project" "$project" >/dev/null
  local codex_settings="$HOME/.codex/hooks.json"
  assert_file_exists "$codex_settings"
  # Must be at hooks.SessionStart[*].hooks[*].command (NOT at top-level
  # .SessionStart[*].script — the pre-fix shape Codex silently ignored).
  local count
  count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                | select(.type=="command" and (.command|endswith("surface-handoffs.sh")))]
              | length' "$codex_settings")"
  assert_eq "$count" "1" "exactly one SessionStart command under hooks.SessionStart"
  # The bad top-level SessionStart key should not exist.
  local bad
  bad="$(jq 'has("SessionStart")' "$codex_settings")"
  assert_eq "$bad" "false" "no top-level SessionStart (Codex ignores it)"
  # The script field shape should not be present anywhere.
  local script_field
  script_field="$(jq '[..|.script? // empty] | length' "$codex_settings")"
  assert_eq "$script_field" "0" "no .script field anywhere (wrong shape)"
}

test_install_into_project_is_idempotent() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  local project="$AGENT_HANDOFF_ROOT/_proj"
  mkdir -p "$project"
  "$repo_root/bin/install-into-project" "$project" >/dev/null
  "$repo_root/bin/install-into-project" "$project" >/dev/null
  "$repo_root/bin/install-into-project" "$project" >/dev/null
  local cc_count cx_count
  cc_count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                   | select((.command//"") | endswith("surface-handoffs.sh"))]
                 | length' "$project/.claude/settings.json")"
  assert_eq "$cc_count" "1" "claude-code: exactly one SessionStart entry after 3 installs"
  cx_count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                   | select((.command//"") | endswith("surface-handoffs.sh"))]
                 | length' "$HOME/.codex/hooks.json")"
  assert_eq "$cx_count" "1" "codex-cli: exactly one SessionStart entry after 3 installs"
}

test_install_into_project_writes_correct_claude_code_format() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  local project="$AGENT_HANDOFF_ROOT/_proj"
  mkdir -p "$project"
  "$repo_root/bin/install-into-project" "$project" >/dev/null
  local cc_settings="$project/.claude/settings.json"
  assert_file_exists "$cc_settings"
  # Per https://code.claude.com/docs/en/hooks each event entry is a
  # matcher group with an inner `hooks` array. A flat
  # {type,command} at the SessionStart level is rejected by
  # Claude Code at startup with "hooks: Expected array, but received
  # undefined".
  local count
  count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                | select(.type=="command" and (.command|endswith("surface-handoffs.sh")))]
              | length' "$cc_settings")"
  assert_eq "$count" "1" "exactly one SessionStart command under hooks.SessionStart[*].hooks"
  # No flat {type,command} entries directly at the SessionStart level —
  # those are the pre-fix shape Claude Code rejects.
  local flat
  flat="$(jq '[.hooks.SessionStart[]? | select(.type and .command)] | length' "$cc_settings")"
  assert_eq "$flat" "0" "no flat {type,command} at SessionStart level (wrong shape)"
  # Every entry under SessionStart must have an inner `hooks` array.
  local valid
  valid="$(jq '[.hooks.SessionStart[]? | select((.hooks|type)=="array")] | length' "$cc_settings")"
  local total
  total="$(jq '.hooks.SessionStart | length' "$cc_settings")"
  assert_eq "$valid" "$total" "every SessionStart entry has inner hooks array"
}

test_install_into_project_migrates_flat_claude_code_session_start() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  local project="$AGENT_HANDOFF_ROOT/_proj"
  mkdir -p "$project/.claude"
  # Pre-fix install wrote flat {type,command} directly under
  # SessionStart. Reinstall must drop the broken entry and produce a
  # well-formed wrapper.
  local stale_cmd
  stale_cmd="$(cd "$repo_root" && pwd -P)/adapters/claude-code/hooks/surface-handoffs.sh"
  cat > "$project/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {"type": "command", "command": "$stale_cmd"}
    ]
  }
}
EOF
  "$repo_root/bin/install-into-project" "$project" >/dev/null
  # No flat {type,command} should remain under SessionStart.
  local flat
  flat="$(jq '[.hooks.SessionStart[]? | select(.type and .command)] | length' \
              "$project/.claude/settings.json")"
  assert_eq "$flat" "0" "flat pre-fix entry removed on reinstall"
  # Exactly one well-formed entry should reference our hook.
  local count
  count="$(jq --arg c "$stale_cmd" '[.hooks.SessionStart[]?.hooks[]?
                                     | select(.command == $c)] | length' \
              "$project/.claude/settings.json")"
  assert_eq "$count" "1" "well-formed entry replaces the flat one"
}

test_install_into_project_migrates_stale_top_level_session_start() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  local project="$AGENT_HANDOFF_ROOT/_proj"
  mkdir -p "$project" "$HOME/.codex"
  # Pre-fix install left a top-level SessionStart with `script` field.
  cat > "$HOME/.codex/hooks.json" <<'EOF'
{
  "SessionStart": [
    {"script": "/stale/old/path"}
  ]
}
EOF
  "$repo_root/bin/install-into-project" "$project" >/dev/null
  local has_top_level
  has_top_level="$(jq 'has("SessionStart")' "$HOME/.codex/hooks.json")"
  assert_eq "$has_top_level" "false" "stale top-level SessionStart removed on reinstall"
}

test_install_into_project_preserves_sibling_hook_in_same_group() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  local project="$AGENT_HANDOFF_ROOT/_proj"
  mkdir -p "$project" "$HOME/.codex"
  # User has manually combined agent-handoff with another hook in ONE
  # matcher group. Reinstall must surgically remove only our entry and
  # keep the sibling, not blow away the entire group.
  local our_cmd
  our_cmd="$(cd "$repo_root" && pwd -P)/adapters/codex-cli/hooks/surface-handoffs.sh"
  cat > "$HOME/.codex/hooks.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {"hooks": [
        {"type":"command","command":"/usr/local/bin/sibling-hook"},
        {"type":"command","command":"$our_cmd"}
      ]}
    ]
  }
}
EOF
  "$repo_root/bin/install-into-project" "$project" >/dev/null
  local sibling_kept
  sibling_kept="$(jq '[.hooks.SessionStart[]?.hooks[]?
                       | select(.command == "/usr/local/bin/sibling-hook")]
                     | length' "$HOME/.codex/hooks.json")"
  assert_eq "$sibling_kept" "1" "sibling hook preserved after surgical removal"
  local our_count
  our_count="$(jq --arg c "$our_cmd" '[.hooks.SessionStart[]?.hooks[]?
                                       | select(.command == $c)] | length' \
              "$HOME/.codex/hooks.json")"
  assert_eq "$our_count" "1" "our entry present exactly once after reinstall"
}

test_install_into_project_preserves_other_hooks() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  local project="$AGENT_HANDOFF_ROOT/_proj"
  mkdir -p "$project"
  mkdir -p "$HOME/.codex"
  # Seed an existing unrelated hook the install must preserve.
  cat > "$HOME/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/existing-hook"}]}
    ],
    "SessionStart": [
      {"hooks":[{"type":"command","command":"/usr/local/bin/existing-session-hook"}]}
    ]
  }
}
EOF
  "$repo_root/bin/install-into-project" "$project" >/dev/null
  local preserved
  preserved="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOME/.codex/hooks.json")"
  assert_eq "$preserved" "/usr/local/bin/existing-hook" "PreToolUse preserved"
  local kept_session
  kept_session="$(jq '[.hooks.SessionStart[]?.hooks[]?
                       | select(.command == "/usr/local/bin/existing-session-hook")]
                     | length' "$HOME/.codex/hooks.json")"
  assert_eq "$kept_session" "1" "existing SessionStart entry kept alongside agent-handoff"
}

###############################################################################
# discovery + run
###############################################################################

tests=(
  test_slug_plain
  test_slug_worker_suffix
  test_slug_worker_numbered
  test_slug_dev_preview
  test_slug_wt_suffix
  test_slug_no_match_left_alone
  test_basename_no_strip
  test_inbox_dir_path
  test_ensure_inbox_creates_dirs
  test_iso_now_format
  test_filename_with_topic
  test_filename_without_topic
  test_atomic_write_creates_file
  test_read_frontmatter_field_name
  test_read_frontmatter_field_branch
  test_read_frontmatter_field_missing
  test_read_frontmatter_does_not_match_body
  test_stamp_received_at_inserts
  test_stamp_received_at_replaces_existing
  test_list_unread_skips_dotfiles_and_non_md
  test_list_unread_missing_dir
  test_archive_moves_file
  test_surface_all_empty_silent
  test_surface_all_prints_and_archives
  test_surface_all_isolation_other_recipient
  test_surface_all_drift_warning
  test_validate_basename_accepts_safe
  test_validate_basename_rejects_unsafe
  test_inbox_dir_rejects_path_traversal
  test_list_unread_skips_symlinks
  test_surface_all_strips_ansi_in_body
  test_surface_all_strips_ansi_in_field
  test_surface_all_skips_preclaimed_file
  test_atomic_write_returns_landing_path
  test_atomic_write_collision_appends_hex_suffix
  test_atomic_write_does_not_overwrite_via_helper
  test_atomic_write_directory_at_dest_treated_as_collision
  test_archive_collision_appends_hex_suffix
  test_print_body_warns_and_dumps_when_frontmatter_unclosed
  test_print_body_warns_on_empty_file
  test_surface_all_surfaces_malformed_with_warning
  test_install_into_project_writes_correct_codex_format
  test_install_into_project_writes_correct_claude_code_format
  test_install_into_project_migrates_flat_claude_code_session_start
  test_install_into_project_is_idempotent
  test_install_into_project_migrates_stale_top_level_session_start
  test_install_into_project_preserves_sibling_hook_in_same_group
  test_install_into_project_preserves_other_hooks
)

printf '=== agent-handoff tests ===\n'
for t in "${tests[@]}"; do
  run_test "$t"
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [[ $fail -gt 0 ]]; then
  printf 'failed:\n'
  for n in "${failed_names[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
