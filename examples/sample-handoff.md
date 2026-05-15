---
name: Auth refactor — pause point after JWT validation lands
description: Auth refactor mid-stream; JWT validation done, refresh-token flow next.
from: assistant
to: assistant
created: 2026-05-15T18:30:00Z
branch: feat/jwt-validation
head: a7c4f12
dirty_files_count: 3
session_tool: claude-code
session_id: cse_01LQHojDfypNRjrAJAoRPntm
topic: auth-refactor
---

# Handoff — Auth refactor pause point

## Status as of 2026-05-15

JWT validation has landed and is green on CI. The refresh-token flow is
next, but the schema decision (rotate-on-use vs. fixed-lifetime tokens)
is unresolved — see Open follow-ups #1.

## Immediate next action

Run `make test-auth` and confirm the new `verifyJwtToken` tests pass on
your machine before touching anything else. The CI green light is from
a clean cache; local state may differ.

## Decisions made (with evidence)

- **Use `jose` over `jsonwebtoken`** for the validator
  (`src/auth/jwt.ts:42`). Rationale: `jose` exposes the `JWTPayload`
  type and supports our `EdDSA` key. PR comment from @reviewer at
  https://github.com/example/repo/pull/421#discussion_r123456.
- **Clock skew tolerance = 30s** (`src/auth/jwt.ts:88`). Matches what
  the upstream IdP documents at <upstream-docs>.

## Recently verified / completed — DO NOT REDO

- Confirmed `JWKS_URL` env var is set in all three deployment
  environments (dev / staging / prod). `kubectl get secret auth-jwks
  -n {ns}` returns the same key id in all three. **Do not** re-run this
  audit.
- Tested key rotation against the staging IdP — works. Rotated key on
  2026-05-15 ~17:50 UTC.

## Open follow-ups

1. **Refresh-token schema decision.** Rotate-on-use is more secure but
   forces all clients to re-issue on every API call; fixed-lifetime is
   simpler but widens the blast radius of a stolen token. Blocked on
   product input — see #1247.
2. **Replace ad-hoc cache in `src/auth/jwks.ts`** with the `jose`
   built-in `createRemoteJWKSet`. Low priority; safe to defer.

## Assumptions / world-model snapshot

- `JWKS_URL` env var is set; the deployment manifest at
  `infra/k8s/auth.yaml` injects it from the `auth-jwks` secret.
- The `auth-jwks` k8s secret in all three envs holds an `EdDSA` public
  key, key id `ed25519-2026-q2`.
- `make test-auth` runs in < 30s and does not hit the network (uses a
  local mock IdP via `tests/fixtures/mock-idp.ts`).

## Verification commands

```bash
git status                                 # expect 3 dirty files (see below)
make test-auth                             # should be green
kubectl get secret auth-jwks -o jsonpath='{.metadata.labels.kid}'   # ed25519-2026-q2
gh pr view 421 --json statusCheckRollup --jq '.statusCheckRollup[].state' | sort -u  # SUCCESS only
```

## Files touched this session

- `src/auth/jwt.ts`
- `src/auth/jwks.ts`
- `tests/auth/jwt.test.ts`

## What NOT to do on resume

- **Do not** swap to `jsonwebtoken`. It was tried first and it does not
  type the `JWTPayload` correctly under `strict: true`. The first hour
  of the session was a dead end on this.
- **Do not** raise the clock skew above 30s. The upstream IdP rejects
  requests with skew > 60s, and we want a safety margin.
- **Do not** start on the refresh-token implementation until #1 in
  Open follow-ups is resolved by product.

## Reader instruction

Addressed to the assistant worktree's next session. The SessionStart
hook should have already moved this file to `read/`; if you're reading
it from `unread/`, the hook isn't installed — wire it in and `mv` this
file by hand.
