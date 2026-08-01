# Feature spec: Bundled Swagger UI

## Goal

Provide an interactive, self-contained API documentation page so an interviewer
can discover and try every Floor Control API endpoint locally without needing a
separate frontend application or internet access.

## Decisions

- Interface -> Swagger UI only; no custom business frontend (source: user)
- Asset delivery -> bundle Swagger UI assets in the application image (source: user)
- UI route -> `/swagger` (source: user)
- Raw contract route -> `/openapi.yaml` (source: user)
- OpenAPI source -> retain the existing hand-maintained `OpenApiSpec.yaml` (source: user)
- Environment availability -> serve Swagger UI in all environments (source: user)
- Contract generation -> do not add automatic OpenAPI generation; Swagger UI renders the existing contract (source: user)

## Assumptions

- The existing `OpenApiSpec.yaml` remains the contract source of truth and CI continues to validate it.
- Swagger UI uses the same origin as the API, avoiding cross-origin configuration for local use.
- The bundled UI does not add authentication; the current API has no authentication boundary.
- Static asset licensing and package provenance will be checked before bundling.

## Out of scope

- A custom floor-control dashboard or frontend application.
- Automatic OpenAPI generation from Phoenix controllers.
- Changes to endpoint behavior, request/response schemas, or business rules.
- Authentication, authorization, or production API access policy.

## Acceptance criteria

1. `GET /swagger` serves a usable Swagger UI page.
2. Swagger UI loads successfully without internet access or CDN requests.
3. Swagger UI loads the API contract from `GET /openapi.yaml`.
4. The UI displays all documented API routes, schemas, request bodies, responses, and examples from the existing contract.
5. The raw `GET /openapi.yaml` response matches the repository's validated `OpenApiSpec.yaml`.
6. The UI can execute representative API requests against the same-origin API.
7. Existing API routes, health checks, Docker/Kind behavior, and CI validation remain unchanged.
8. README documents `/swagger` and `/openapi.yaml` for local, Docker, and Kind usage.

## Impacted areas

- Phoenix static asset serving and routes
- Bundled Swagger UI assets and dependency/license handling
- `OpenApiSpec.yaml` delivery
- README/API usage documentation
- Endpoint/integration tests and CI asset validation

## Open risks

- Swagger UI asset version and licensing must be pinned and reviewed.
- Serving interactive API documentation in all environments is intentional but should be reconsidered if authentication is introduced later.

GATE: approved by user 2026-08-01
