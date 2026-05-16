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

test_surface_all_skips_live_preclaimed_file() {
  # Simulates a sibling hook that has already claimed the file AND is
  # still alive (PID maps to a live process): the current hook's
  # recovery sweep must leave it alone, and list_unread skips dotfiles,
  # so the file should be silently untouched.
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  # $$ inside this subshell is the running test shell — guaranteed live
  # for the duration of the test (vs the original test's hardcoded
  # 99999, which is almost always dead and would now be recovered by
  # the stale-claim sweep).
  local live_pid=$$
  local pre="$AGENT_HANDOFF_ROOT/_fake/assistant/unread/.claim-${live_pid}-foo.md"
  write_sample_handoff "$pre"
  local out
  out="$(agent_handoff_surface_all 1 2>&1)"
  # Dotfiles are not listed in the first place, and the sweep saw the
  # PID is alive — so output should be empty and the claim untouched.
  assert_eq "$out" "" "live pre-claimed dotfile not surfaced"
  assert_file_exists "$pre"
}

test_surface_all_recovers_stale_claim_from_dead_pid() {
  # A claim file left over from a hook that died (SIGPIPE, SIGKILL,
  # panic) before it could archive must be recovered and surfaced.
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  # Grab a guaranteed-dead PID: spawn a sleep 0 in the background, wait
  # for it to exit, then reuse its PID. PID reuse is technically
  # possible but extremely unlikely in the millisecond-scale window of
  # a unit test.
  local dead_pid
  ( sleep 0 ) &
  dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  # Belt-and-suspenders: confirm it's actually dead before we rely on it.
  if kill -0 "$dead_pid" 2>/dev/null; then
    printf '   sleep 0 still alive at pid %d — flaky env?\n' "$dead_pid" >&2
    exit 1
  fi
  local orig_name="20260516T100000Z-from-sender.md"
  local stuck="$AGENT_HANDOFF_ROOT/_fake/assistant/unread/.claim-${dead_pid}-${orig_name}"
  write_sample_handoff "$stuck"

  local out
  out="$(agent_handoff_surface_all 1 2>&1)"

  # The stuck file is gone from unread/ (under both names).
  if [[ -e "$stuck" ]]; then
    printf '   stale claim should have been swept: %s\n' "$stuck" >&2
    exit 1
  fi
  if [[ -e "$AGENT_HANDOFF_ROOT/_fake/assistant/unread/$orig_name" ]]; then
    printf '   recovered file should also be archived, not lingering in unread\n' >&2
    exit 1
  fi
  # The handoff was surfaced.
  assert_contains "$out" "Test handoff" "recovered handoff was surfaced"
  assert_contains "$out" "1 UNTRUSTED handoff(s) for assistant" "header counts the recovered file"
  # It landed in read/ under its original name.
  local archived="$AGENT_HANDOFF_ROOT/_fake/assistant/read/$orig_name"
  assert_file_exists "$archived"
  # received_at was stamped.
  local rcv
  rcv="$(agent_handoff_read_frontmatter_field "$archived" received_at)"
  if [[ -z "$rcv" ]]; then
    printf '   received_at not stamped on recovered file\n' >&2
    exit 1
  fi
}

test_surface_all_skips_pid_zero_claim() {
  # `.claim-0-<orig>.md` would otherwise stick forever: `kill -0 0`
  # signals the entire process group and always succeeds, so the
  # sweep would treat PID 0 as "live" indefinitely. We special-case
  # all-zero PIDs and skip recovery for them.
  #
  # No real hook ever owns PID 0, so the file is unrecoverable
  # automatically — leaving it in place lets a human notice and
  # decide what to do (likely a hand-edited or malicious file).
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  local orig_name="20260516T100000Z-from-sender.md"
  local stuck="$AGENT_HANDOFF_ROOT/_fake/assistant/unread/.claim-0-${orig_name}"
  write_sample_handoff "$stuck"

  local out
  out="$(agent_handoff_surface_all 1 2>&1)"

  # File still in unread/ under the .claim-0- name (not recovered).
  assert_file_exists "$stuck"
  # Nothing surfaced (the file remained a dotfile and was not picked up).
  assert_eq "$out" "" "no output when only a .claim-0-* file exists"
}

test_surface_all_does_not_clobber_caller_exit_trap() {
  # surface_all no longer installs an EXIT trap (the in-process
  # self-heal was removed — recovery is handled by the next-invocation
  # sweep in agent_handoff_recover_stale_claims). This test pins the
  # invariant: a caller's pre-existing EXIT trap must survive a call
  # to surface_all unchanged.
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  local f="$AGENT_HANDOFF_ROOT/_fake/assistant/unread/20260516T100000Z-from-sender.md"
  write_sample_handoff "$f"

  local sentinel="$AGENT_HANDOFF_ROOT/caller-trap-fired"
  # Verify in a subshell that the caller's trap fires on subshell exit.
  (
    trap 'touch "'"$sentinel"'"' EXIT
    agent_handoff_surface_all 1 >/dev/null 2>&1
    # Subshell exits here; if the trap was preserved, the sentinel
    # is created.
  )
  if [[ ! -e "$sentinel" ]]; then
    printf '   caller EXIT trap was dropped by surface_all\n' >&2
    exit 1
  fi
}

test_surface_all_leaves_stuck_claim_for_next_sweep_to_recover() {
  # When THIS hook is killed mid-loop, the leftover .claim-<our-pid>-<orig>
  # dotfile is NOT cleaned up in-process (the EXIT-trap self-heal was
  # removed — it didn't work portably with local arrays). Instead, the
  # NEXT invocation's recover_stale_claims sweep finds the claim,
  # observes our PID is dead via `kill -0`, and restores it. This test
  # pins the two-step recovery contract: simulated crash leaves a stuck
  # claim, second surface_all call finds + surfaces it.
  setup_fake_worktree assistant
  agent_handoff_ensure_inbox _fake assistant
  local unread_dir="$AGENT_HANDOFF_ROOT/_fake/assistant/unread"
  local f1="$unread_dir/20260516T100000Z-from-sender-aaa.md"
  local f2="$unread_dir/20260516T100001Z-from-sender-bbb.md"
  write_sample_handoff "$f1"
  write_sample_handoff "$f2"

  # Run the crashing invocation as a NEW bash process (not a subshell)
  # so `$$` inside it is the crashed process's own PID — which becomes
  # dead after the process exits, enabling the next sweep to detect it
  # via `kill -0`. A `( ... )` subshell would leak `$$` from the
  # parent test shell, which stays alive and would defeat the sweep.
  local crash_script="$AGENT_HANDOFF_ROOT/_crash.sh"
  cat > "$crash_script" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$repo_root/lib/slug.sh"
source "$repo_root/lib/inbox.sh"
export AGENT_HANDOFF_ROOT="$AGENT_HANDOFF_ROOT"
agent_handoff_resolve_root() { printf '%s' "\$AGENT_HANDOFF_ROOT/_fake/assistant"; }
agent_handoff_worktree_basename() { printf 'assistant'; }
agent_handoff_canonical_slug() { printf '_fake'; }
agent_handoff_stamp_received_at_call_count=0
agent_handoff_stamp_received_at() {
  agent_handoff_stamp_received_at_call_count=\$((agent_handoff_stamp_received_at_call_count + 1))
  if [[ "\$agent_handoff_stamp_received_at_call_count" -ge 2 ]]; then
    exit 1
  fi
  return 0
}
agent_handoff_surface_all 1 >/dev/null 2>&1
EOF
  chmod +x "$crash_script"
  bash "$crash_script" >/dev/null 2>&1
  local crash_status=$?
  # The crash script exits non-zero from the simulated kill. If it
  # somehow succeeded, the test setup is wrong.
  if [[ $crash_status -eq 0 ]]; then
    printf '   expected crash script to exit non-zero, got 0\n' >&2
    exit 1
  fi

  # At least one stuck claim should remain (the second file's claim
  # was never restored because the in-process trap is gone). It's the
  # next sweep's job to recover it.
  shopt -s nullglob
  local leftover=("$unread_dir"/.claim-*)
  shopt -u nullglob
  if [[ ${#leftover[@]} -eq 0 ]]; then
    printf '   expected at least one stuck claim left by crashed hook\n' >&2
    exit 1
  fi

  # Now a fresh invocation runs the recovery sweep, picks up the
  # restored file(s), and surfaces them. Every handoff must end up
  # archived in read/ — none stuck as claims.
  agent_handoff_surface_all 1 >/dev/null 2>&1

  shopt -s nullglob
  local after=("$unread_dir"/.claim-*)
  shopt -u nullglob
  if [[ ${#after[@]} -gt 0 ]]; then
    printf '   stuck claims survived the recovery sweep: %s\n' "${after[*]}" >&2
    exit 1
  fi

  shopt -s nullglob
  local unread_left=("$unread_dir"/*.md)
  local archived=("$AGENT_HANDOFF_ROOT/_fake/assistant/read"/*.md)
  shopt -u nullglob
  if [[ ${#unread_left[@]} -gt 0 ]]; then
    printf '   files left in unread/ after recovery: %s\n' "${unread_left[*]}" >&2
    exit 1
  fi
  assert_eq "${#archived[@]}" "2" "both handoffs end up archived after the recovery sweep"
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
# bin/install — user-level global install
###############################################################################
#
# bin/install writes to $HOME (which the test harness pins to a tmp dir),
# so these tests do not pollute the user's real ~/.claude or ~/.codex.

test_install_writes_correct_claude_code_format() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  "$repo_root/bin/install" >/dev/null
  local cc_settings="$HOME/.claude/settings.json"
  assert_file_exists "$cc_settings"
  # Per https://code.claude.com/docs/en/hooks each event entry is a
  # matcher group with an inner `hooks` array. A flat {type,command}
  # at the SessionStart level is rejected by Claude Code at startup.
  local count
  count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                | select(.type=="command" and (.command|endswith("surface-handoffs.sh")))]
              | length' "$cc_settings")"
  assert_eq "$count" "1" "exactly one SessionStart command under hooks.SessionStart[*].hooks"
  # No flat {type,command} entries directly at SessionStart.
  local flat
  flat="$(jq '[.hooks.SessionStart[]? | select(.type and .command)] | length' "$cc_settings")"
  assert_eq "$flat" "0" "no flat {type,command} at SessionStart level (wrong shape)"
  # Every entry under SessionStart must have an inner `hooks` array.
  local valid total
  valid="$(jq '[.hooks.SessionStart[]? | select((.hooks|type)=="array")] | length' "$cc_settings")"
  total="$(jq '.hooks.SessionStart | length' "$cc_settings")"
  assert_eq "$valid" "$total" "every SessionStart entry has inner hooks array"
}

test_install_writes_correct_codex_format() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  "$repo_root/bin/install" >/dev/null
  local cx_settings="$HOME/.codex/hooks.json"
  assert_file_exists "$cx_settings"
  # Same matcher-group + inner-hooks shape required by Codex.
  local count
  count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                | select(.type=="command" and (.command|endswith("surface-handoffs.sh")))]
              | length' "$cx_settings")"
  assert_eq "$count" "1" "exactly one SessionStart command under hooks.SessionStart"
  # The pre-fix top-level SessionStart key must not exist.
  local bad
  bad="$(jq 'has("SessionStart")' "$cx_settings")"
  assert_eq "$bad" "false" "no top-level SessionStart (Codex ignores it)"
  # No .script field shape anywhere (wrong, pre-fix).
  local script_field
  script_field="$(jq '[..|.script? // empty] | length' "$cx_settings")"
  assert_eq "$script_field" "0" "no .script field anywhere (wrong shape)"
}

test_install_is_idempotent() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  "$repo_root/bin/install" >/dev/null
  "$repo_root/bin/install" >/dev/null
  "$repo_root/bin/install" >/dev/null
  local cc_count cx_count
  cc_count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                   | select((.command//"") | endswith("surface-handoffs.sh"))]
                 | length' "$HOME/.claude/settings.json")"
  assert_eq "$cc_count" "1" "claude-code: exactly one SessionStart entry after 3 installs"
  cx_count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                   | select((.command//"") | endswith("surface-handoffs.sh"))]
                 | length' "$HOME/.codex/hooks.json")"
  assert_eq "$cx_count" "1" "codex-cli: exactly one SessionStart entry after 3 installs"
}

test_install_preserves_unrelated_hooks() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  # Seed both files with unrelated entries; the installer must preserve them.
  cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/cc-pre"}]}
    ],
    "SessionStart": [
      {"hooks":[{"type":"command","command":"/usr/local/bin/cc-other-session"}]}
    ]
  }
}
EOF
  cat > "$HOME/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {"matcher":"Bash","hooks":[{"type":"command","command":"/usr/local/bin/cx-pre"}]}
    ],
    "SessionStart": [
      {"hooks":[{"type":"command","command":"/usr/local/bin/cx-other-session"}]}
    ]
  }
}
EOF
  "$repo_root/bin/install" >/dev/null
  # Claude Code: PreToolUse preserved
  local cc_pre
  cc_pre="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOME/.claude/settings.json")"
  assert_eq "$cc_pre" "/usr/local/bin/cc-pre" "claude-code PreToolUse preserved"
  # Claude Code: other SessionStart kept alongside ours
  local cc_other
  cc_other="$(jq '[.hooks.SessionStart[]?.hooks[]?
                   | select(.command == "/usr/local/bin/cc-other-session")] | length' \
              "$HOME/.claude/settings.json")"
  assert_eq "$cc_other" "1" "claude-code other SessionStart kept alongside agent-handoff"
  # Codex CLI: PreToolUse preserved
  local cx_pre
  cx_pre="$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOME/.codex/hooks.json")"
  assert_eq "$cx_pre" "/usr/local/bin/cx-pre" "codex-cli PreToolUse preserved"
  # Codex CLI: other SessionStart kept alongside ours
  local cx_other
  cx_other="$(jq '[.hooks.SessionStart[]?.hooks[]?
                   | select(.command == "/usr/local/bin/cx-other-session")] | length' \
              "$HOME/.codex/hooks.json")"
  assert_eq "$cx_other" "1" "codex-cli other SessionStart kept alongside agent-handoff"
}

test_install_migrates_flat_claude_code_entry() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  mkdir -p "$HOME/.claude"
  # Pre-fix install wrote flat {type,command} directly under
  # SessionStart for agent-handoff itself.
  local stale_cmd
  stale_cmd="$(cd "$repo_root" && pwd -P)/adapters/claude-code/hooks/surface-handoffs.sh"
  cat > "$HOME/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {"type": "command", "command": "$stale_cmd"}
    ]
  }
}
EOF
  "$repo_root/bin/install" >/dev/null
  # No flat {type,command} should remain under SessionStart.
  local flat
  flat="$(jq '[.hooks.SessionStart[]? | select(.type and .command)] | length' \
              "$HOME/.claude/settings.json")"
  assert_eq "$flat" "0" "flat pre-fix entry removed on reinstall"
  local count
  count="$(jq --arg c "$stale_cmd" '[.hooks.SessionStart[]?.hooks[]?
                                     | select(.command == $c)] | length' \
              "$HOME/.claude/settings.json")"
  assert_eq "$count" "1" "well-formed entry replaces the flat one"
}

test_install_migrates_stale_top_level_codex_session_start() {
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  mkdir -p "$HOME/.codex"
  # Pre-fix install left a top-level SessionStart with `script` field
  # (wrong shape that Codex silently ignored).
  cat > "$HOME/.codex/hooks.json" <<'EOF'
{
  "SessionStart": [
    {"script": "/stale/old/path"}
  ]
}
EOF
  "$repo_root/bin/install" >/dev/null
  local has_top_level
  has_top_level="$(jq 'has("SessionStart")' "$HOME/.codex/hooks.json")"
  assert_eq "$has_top_level" "false" "stale top-level SessionStart removed on reinstall"
}

test_install_wraps_unrelated_flat_claude_code_entries() {
  # A pre-fix install that targeted an unrelated tool may have left a
  # flat {type,command} entry that wasn't ours. Claude Code rejects the
  # whole file when any flat entry exists, so the user's other hook was
  # broken anyway. The installer should migrate it to a valid wrapper
  # rather than silently dropping it.
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  mkdir -p "$HOME/.claude"
  local our_cmd
  our_cmd="$(cd "$repo_root" && pwd -P)/adapters/claude-code/hooks/surface-handoffs.sh"
  cat > "$HOME/.claude/settings.json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {"type": "command", "command": "$our_cmd"},
      {"type": "command", "command": "/usr/local/bin/unrelated-flat"}
    ]
  }
}
EOF
  "$repo_root/bin/install" >/dev/null
  local flat
  flat="$(jq '[.hooks.SessionStart[]? | select(.type and .command)] | length' \
              "$HOME/.claude/settings.json")"
  assert_eq "$flat" "0" "no flat entries remain"
  local wrapped
  wrapped="$(jq '[.hooks.SessionStart[]?.hooks[]?
                  | select(.command == "/usr/local/bin/unrelated-flat")]
                | length' "$HOME/.claude/settings.json")"
  assert_eq "$wrapped" "1" "unrelated flat entry migrated into a matcher group"
  local our_count
  our_count="$(jq --arg c "$our_cmd" '[.hooks.SessionStart[]?.hooks[]?
                                       | select(.command == $c)] | length' \
              "$HOME/.claude/settings.json")"
  assert_eq "$our_count" "1" "our entry present exactly once"
}

test_install_creates_skill_symlink() {
  "$repo_root/bin/install" >/dev/null
  local dest="$HOME/.claude/skills/handoff"
  if [[ ! -L "$dest" ]]; then
    printf '   expected symlink at %s\n' "$dest" >&2; exit 1
  fi
  local target
  target="$(readlink "$dest")"
  local expected="$repo_root/adapters/claude-code/skill"
  assert_eq "$target" "$expected" "skill symlink points at adapters/claude-code/skill"
}

test_install_creates_codex_plugin_symlink() {
  "$repo_root/bin/install" >/dev/null
  local dest="$HOME/.codex/plugins/agent-handoff"
  if [[ ! -L "$dest" ]]; then
    printf '   expected symlink at %s\n' "$dest" >&2; exit 1
  fi
  local target
  target="$(readlink "$dest")"
  local expected="$repo_root/adapters/codex-cli"
  assert_eq "$target" "$expected" "codex plugin symlink points at adapters/codex-cli"
}

test_install_removes_prior_install_from_different_repo_path() {
  # Critical: if a user moves the repo, clones a second copy, or runs
  # from a different worktree, the OLD absolute path must be removed
  # rather than left behind as a dead-or-duplicate hook on every session
  # in every project. Match by stable suffix, not exact path.
  if ! command -v jq >/dev/null 2>&1; then
    printf '   skipping: jq not available\n' >&2; return 0
  fi
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  # Seed both files with hooks from a DIFFERENT repo location — same
  # suffix, different prefix.
  cat > "$HOME/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {"hooks":[{"type":"command","command":"/old/clone/of/agent-handoff/adapters/claude-code/hooks/surface-handoffs.sh"}]}
    ]
  }
}
EOF
  cat > "$HOME/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {"hooks":[{"type":"command","command":"/old/clone/of/agent-handoff/adapters/codex-cli/hooks/surface-handoffs.sh"}]}
    ]
  }
}
EOF
  "$repo_root/bin/install" >/dev/null
  # Old absolute path should be gone from both.
  local cc_old
  cc_old="$(jq '[.hooks.SessionStart[]?.hooks[]?
                 | select(.command | startswith("/old/clone"))] | length' \
              "$HOME/.claude/settings.json")"
  assert_eq "$cc_old" "0" "claude-code: stale absolute path from prior repo location removed"
  local cx_old
  cx_old="$(jq '[.hooks.SessionStart[]?.hooks[]?
                 | select(.command | startswith("/old/clone"))] | length' \
              "$HOME/.codex/hooks.json")"
  assert_eq "$cx_old" "0" "codex-cli: stale absolute path from prior repo location removed"
  # Exactly one current entry should exist in each.
  local cc_count cx_count
  cc_count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                   | select((.command//"") | endswith("/adapters/claude-code/hooks/surface-handoffs.sh"))]
                 | length' "$HOME/.claude/settings.json")"
  assert_eq "$cc_count" "1" "claude-code: exactly one current entry after migration"
  cx_count="$(jq '[.hooks.SessionStart[]?.hooks[]?
                   | select((.command//"") | endswith("/adapters/codex-cli/hooks/surface-handoffs.sh"))]
                 | length' "$HOME/.codex/hooks.json")"
  assert_eq "$cx_count" "1" "codex-cli: exactly one current entry after migration"
}

test_install_is_idempotent_for_symlinks() {
  "$repo_root/bin/install" >/dev/null
  "$repo_root/bin/install" >/dev/null
  "$repo_root/bin/install" >/dev/null
  local skill_target plugin_target
  skill_target="$(readlink "$HOME/.claude/skills/handoff")"
  plugin_target="$(readlink "$HOME/.codex/plugins/agent-handoff")"
  assert_eq "$skill_target" "$repo_root/adapters/claude-code/skill" "skill symlink stable after 3 installs"
  assert_eq "$plugin_target" "$repo_root/adapters/codex-cli" "codex plugin symlink stable after 3 installs"
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
  test_surface_all_skips_live_preclaimed_file
  test_surface_all_recovers_stale_claim_from_dead_pid
  test_surface_all_skips_pid_zero_claim
  test_surface_all_leaves_stuck_claim_for_next_sweep_to_recover
  test_surface_all_does_not_clobber_caller_exit_trap
  test_atomic_write_returns_landing_path
  test_atomic_write_collision_appends_hex_suffix
  test_atomic_write_does_not_overwrite_via_helper
  test_atomic_write_directory_at_dest_treated_as_collision
  test_archive_collision_appends_hex_suffix
  test_print_body_warns_and_dumps_when_frontmatter_unclosed
  test_print_body_warns_on_empty_file
  test_surface_all_surfaces_malformed_with_warning
  test_install_writes_correct_claude_code_format
  test_install_writes_correct_codex_format
  test_install_is_idempotent
  test_install_preserves_unrelated_hooks
  test_install_migrates_flat_claude_code_entry
  test_install_migrates_stale_top_level_codex_session_start
  test_install_wraps_unrelated_flat_claude_code_entries
  test_install_creates_skill_symlink
  test_install_creates_codex_plugin_symlink
  test_install_removes_prior_install_from_different_repo_path
  test_install_is_idempotent_for_symlinks
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
