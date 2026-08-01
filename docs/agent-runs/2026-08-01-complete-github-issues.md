# Run: Issue #2 floor ownership schema

Status: active; approved and pending merge
Started: 2026-08-01

## Objective

Add PostgreSQL persistence for one current floor owner per radio group and indefinitely retained audit events.

## Handoffs

- Backend: ownership and audit migrations, Ecto schemas, database constraints, append-only protection, and integration tests.
- Reviews: general, security, and performance reviews approved; acceptance verification accepted both persistence-scope criteria.

## Changes

- Added `floor_ownerships` with a database-enforced unique group index.
- Added `floor_audit_events` with a group/occurred-at/id index for deterministic history ordering.
- Added Ecto schemas, changesets, validation, and uniqueness constraint translation.
- Added database check constraints for priority ranges and an append-only audit trigger.
- Added database integration tests for migration objects, persistence constraints, uniqueness collision safety, and audit tie-breaking.

## Decisions

- Ownership uses one row per current group and a unique database index; no process-local uniqueness check is relied upon.
- Audit ordering uses `occurred_at` followed by the immutable primary-key `id`; the composite index matches that access pattern.
- Audit history is append-only at the database boundary because indefinite retention requires preventing mutation and deletion; a trigger is the least-privilege enforceable mechanism for the application role.
- No ADR was required: the append-only invariant follows directly from retained audit history and does not introduce an alternative architecture.

## Verification

- Passed `mix format --check-formatted`.
- Passed `mix compile --warnings-as-errors`.
- Passed test database rollback and migration.
- Passed `MIX_ENV=test mix test` with 18 tests.
- Repeated the ownership test file 10 times successfully with `--repeat-until-failure 10`.
- PostgreSQL was started locally in Docker because no host PostgreSQL listener was available initially.

## Reviews

- General: approved after resolving priority checks, synchronized concurrency setup, and independent audit mutation tests.
- Security: approved after adding database-enforced priority checks and append-only UPDATE, DELETE, and TRUNCATE protection.
- Performance: approved; the group/time/id audit index supports deterministic history queries without speculative optimization.
- Acceptance: accepted; 18 tests passed and both issue #2 persistence criteria were verified.

## Risks And Blockers

- Audit triggers protect against normal application-role mutations; a database owner or superuser can still alter schema or disable triggers.
- Prerequisite PR #10 is merged; no prerequisite blocker remains.

## Outcome

Issue #2 implementation and reviews are complete. Merge is pending through the approved pull-request checks and dependency order.
