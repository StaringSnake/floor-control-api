# Run: Issues #2 and #3 floor control

Status: pending merge; issue #2 merged, issue #3 approved and acceptance-verified
Started: 2026-08-01

## Objective

Implement floor ownership persistence and obtain/release operations for radio groups.

## Handoffs

- Backend: ownership and audit migrations, Ecto schemas, database constraints, append-only protection, and integration tests.
- Issue #3 handoff: public Floors context, Phoenix endpoints, validation/error mapping, atomic audit transitions, and concurrent database tests.
- Reviews: issue #2 general, security, and performance reviews approved; issue #3 general, security, performance, and acceptance reviews approved.

## Changes

- Added `floor_ownerships` with a database-enforced unique group index.
- Added `floor_audit_events` with a group/occurred-at/id index for deterministic history ordering.
- Added Ecto schemas, changesets, validation, and uniqueness constraint translation.
- Added database check constraints for priority ranges and an append-only audit trigger.
- Added database integration tests for migration objects, persistence constraints, uniqueness collision safety, and audit tie-breaking.
- Added obtain and release operations with idempotent same-holder obtains, holder-only release, and transactional audit writes.
- Added HTTP routes/controllers, validation and documented 400/403/409 errors, plus OpenAPI clarification.
- Added context/API/concurrency coverage for ownership, audit atomicity, idempotency, validation, conflict, and authorization behavior.

## Decisions

- Ownership uses one row per current group and a unique database index; no process-local uniqueness check is relied upon.
- Audit ordering uses `occurred_at` followed by the immutable primary-key `id`; the composite index matches that access pattern.
- Audit history is append-only at the database boundary because indefinite retention requires preventing mutation and deletion; a trigger is the least-privilege enforceable mechanism for the application role.
- No ADR was required: the append-only invariant follows directly from retained audit history and does not introduce an alternative architecture.
- Obtain serializes an existing group row with `FOR UPDATE`; the database unique index resolves concurrent first obtains, and a losing request re-reads the committed owner to preserve idempotency/conflict semantics.
- Issue #3 keeps priority as validated input but does not preempt an occupied floor; all occupied-by-another requests return `409`.
- Unique-index recovery performs one deterministic post-rollback owner read; it returns same-holder success, another-holder conflict, or bounded contention without recursive retries.
- Identifiers are normalized at the trust boundary and limited to the existing database limit of 255 characters; no migration was needed.
- Missing path segments remain standard router `404` responses because they cannot match the documented operations; blank matched segments return documented `400` responses.

## Verification

- Passed `mix format --check-formatted`.
- Passed `mix compile --warnings-as-errors`.
- Passed test database rollback and migration.
- Passed `MIX_ENV=test mix test` with 18 tests.
- Repeated the ownership test file 10 times successfully with `--repeat-until-failure 10`.
- PostgreSQL was started locally in Docker because no host PostgreSQL listener was available initially.
- Issue #2 merged in PR #11 at `d730e14`; issue #3 verification is recorded below after implementation.

## Issue #3 Verification

- Passed `mix format --check-formatted`.
- Passed `mix compile --warnings-as-errors`.
- Passed `MIX_ENV=test mix ecto.migrate` with no schema changes required.
- Passed `MIX_ENV=test mix test` with 34 tests.
- Passed focused context/API tests (including 10 isolated same- and different-holder races) 10 times with `--repeat-until-failure 10`.
- Passed `npx --yes swagger-cli validate OpenApiSpec.yaml`.

## Issue #3 Re-review Disposition

- General/security/performance: resolved unbounded retry and oversized identifier findings with bounded recovery, 255-character validation, and concurrent same-holder coverage.
- Contract: added HTTP idempotency, empty-body, invalid-release, boundary-length, and missing-path tests; documented the 400-versus-404 routing boundary.
- Performance preemption finding: rejected as out of scope; priority remains validation-only and preemption remains issue #6.
- Reviewer selection: general correctness; security for validation/ownership; performance for transactions/concurrency; acceptance verification.

## Issue #3 Risks And Blockers

- No authentication is intentionally present; `userId` remains the simulated caller identity for this issue.
- The existing ConnCase deprecation warning remains outside this issue's scope.
- No review blockers remain; issue #3 is pending merge.

## Reviews

- General: APPROVE after resolving priority checks, bounded retry, boundary validation, routing clarification, and explicit repeated concurrency coverage.
- Security: APPROVE; selected for validation and ownership review, with max-255 identifier enforcement and holder-only release verified.
- Performance: APPROVE; selected for transaction/concurrency review. Initial re-review was blocked by missing diff visibility; exact-diff re-review approved. Preemption finding was rejected as issue #6 scope.
- Acceptance: ACCEPT; all six issue #3 criteria pass with 34 tests.

## Risks And Blockers

- Audit triggers protect against normal application-role mutations; a database owner or superuser can still alter schema or disable triggers.
- Prerequisite PR #10 is merged; no prerequisite blocker remains.

## Outcome

Issue #2 implementation and reviews are complete and merged. Issue #3 implementation, reviews, and acceptance verification are complete and merged in PR #12 at `0efe838`.

## Issue #4 Handoff

- Issue #3 was merged in PR #12 at `0efe838`; issue #4 is active and review pending.
- Issue #4 adds a supervised single-instance timeout sweep with a default 30-second
  `FLOOR_TIMEOUT_SECONDS` configuration, persisted `acquired_at` authority, locked
  stale-row verification, `timed_out` audit events, and restart recovery.

## Issue #4 Review Findings

- Resolved automatic-process coverage by arming the supervised mailbox timer only
  after SQL Sandbox ownership is established; tests cover automatic expiry, audit,
  re-obtain, fresh-owner preservation, and supervised child restart recovery.
- Resolved the timeout query N+1 finding by treating the bounded `FOR UPDATE SKIP
  LOCKED` batch as authoritative inside its transaction; the lock prevents obtain
  or release from replacing a candidate before its audit/delete commit.
- Replaced the ownership index with a concurrent `(acquired_at, id)` index and
  explicit forward/rollback migration functions with DDL and migration locks
  disabled as required by PostgreSQL concurrent index creation.
- Bounded timeout parsing against the supported `DateTime` range and changed sweep
  cadence to half the configured timeout, capped at 60 seconds; this avoids fixed
  one-second polling for large configurations.
- Narrowed failure handling to expected database exceptions. Unexpected failures
  remain supervisor-visible; no broad system-exit catch is used.
- Atomicity remains guaranteed by the single transaction enclosing locked selection,
  audit insertion, and ownership deletion; integration tests assert both outcomes.
- Status: findings resolved; pending re-review.

## Issue #4 Performance Follow-up

- Resolved the expired-backlog finding by returning whether the bounded expiration
  batch was full. A full batch schedules a 1ms mailbox follow-up; empty or partial
  batches return to normal cadence, and database errors use normal retry cadence.
- Added a deterministic 205-row automatic backlog test proving all rows and exact
  `timed_out` audits drain promptly from one activation without a 15-second wait.
- Status: performance follow-up implemented; pending re-review.

## Issue #4 Final General Review Follow-up

- Added a tracked timer token/reference to `FloorTimeout`; initialization arms one
  chain, repeated `arm/1` calls are idempotent, current sweep messages clear their
  reference before scheduling exactly one successor, and stale tokens are ignored.
- Added repeated-arm coverage and backlog timing assertions showing the two
  immediate full-batch follow-ups occur well before the configured 2-second normal
  cadence and before three normal intervals.
- General and security reviews approve; performance review approves after backlog
  follow-up; acceptance is ACCEPT with 40 tests. Issue #4 is ready for merge.

## Issue #5 Handoff

- Issue #4 merged in PR #13 at `5a4d7b2`; issue #5 adds current-holder lookup and
  is pending review.
- `GET /groups/{groupId}/floor` always returns `200` for a valid groupId with
  either a nullable `holder` or `{userId, priority, acquiredAt}`. Invalid
  identifiers remain `400`, and omitted path segments remain router `404`.
- Lookup performs one indexed current-ownership read and has no audit or other
  side effects. Release and timeout leave subsequent lookup responses empty.
- The date contract is an ISO 8601 UTC `date-time` with microsecond precision.

## Issue #5 Review Disposition

- Corrected `CurrentHolderResponse.holder` to use OpenAPI 3.0-compatible
  `nullable: true` with `allOf` around the `Holder` reference; nullable is no
  longer a sibling of `$ref`.
- The documented `holder: null` example remains the unoccupied response, and
  the existing API test verifies that exact runtime JSON shape.
- General and performance reviews approve. Security review was skipped because
  this is a read-only public lookup with no new authorization boundary, and
  holder exposure is part of the user-approved contract.
- Acceptance is ACCEPT with 49 tests. Issue #5 is pending merge.
