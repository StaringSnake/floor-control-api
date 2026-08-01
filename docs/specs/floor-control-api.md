# Feature spec: Floor Control API

## Goal

Build a Dockerized Phoenix REST API that manages mutually exclusive floor ownership for radio groups, persists state in PostgreSQL, supports release and timeout behavior, and exposes the selected bonus capabilities without handling audio.

## Decisions

- Implementation stack: Elixir + Phoenix.
- Persistence: PostgreSQL + Ecto.
- Repeated obtain by the current holder is idempotent and returns success.
- Release by a non-holder returns `403 Forbidden`.
- `groupId` and `userId` must be non-empty trimmed strings.
- Include CI, holder lookup, timeout, audit history, and prioritized requests.
- Default timeout: 30 seconds, configurable by server settings.
- Higher-priority requests immediately preempt the current holder.
- Equal or lower priority requests return `409 Conflict`.
- Priority is an integer from `1` to `10`, defaulting to `1`.
- Audit history is retained indefinitely.
- No authentication; `userId` identifies the simulated caller.
- The supplied OpenAPI contract will be corrected and extended for the selected features.

## Assumptions

- Only one floor ownership row may exist per radio group.
- Ownership transitions and audit events are committed atomically.
- Concurrent requests are resolved using database transactions and constraints.
- Timeout expiry creates an audit event.
- Audit records include group, user, transition type, priority, and timestamps.
- Initial timeout scheduling assumes a single service instance.

## Out of scope

- Audio broadcasting or media transport.
- Authentication or user management.
- Request queues.
- Kubernetes deployment.
- Distributed locking beyond PostgreSQL guarantees.

## Acceptance criteria

1. `POST /groups/{groupId}/floor` grants an unoccupied group’s floor.
2. Equal or lower priority requests for an occupied floor return `409 Conflict`.
3. Repeated obtain requests by the current holder are idempotent.
4. Higher-priority requests atomically preempt the current holder and create audit records.
5. `DELETE /groups/{groupId}/floor/{userId}` only succeeds for the current holder; other callers receive `403 Forbidden`.
6. Missing, blank, or whitespace-only identifiers and invalid request bodies return `400 Bad Request`.
7. Concurrent requests cannot create more than one floor holder per group.
8. Floors automatically release after the configured timeout, defaulting to 30 seconds.
9. A holder lookup endpoint returns the current holder or the documented empty response.
10. An audit endpoint returns retained floor history in deterministic order.
11. The OpenAPI document validates and describes all implemented endpoints and responses.
12. Tests cover success, validation, conflicts, forbidden releases, idempotency, priority, timeout, audit, and concurrency.
13. Docker instructions start the API and PostgreSQL dependencies.
14. CI runs formatting, compilation, tests, and OpenAPI validation.

## Impacted areas

- Phoenix HTTP routes and controllers.
- Ecto schemas, migrations, constraints, and transactions.
- Floor ownership and audit persistence.
- Timeout scheduling and expiry.
- OpenAPI contract.
- Docker and CI configuration.
- README run instructions.
- Unit, integration, and concurrency tests.

## Open risks

- Multi-instance timeout scheduling requires additional coordination.
- Indefinite audit retention is suitable for the challenge but not necessarily production.

GATE: spec approved