# Agent run: bundled Swagger UI

- Date: 2026-08-01
- Issue: #24
- Branch: `feature/bundled-swagger-ui`
- Status: final review approved — pending merge

## Scope

Added offline Swagger UI at `/swagger` and the hand-maintained OpenAPI contract
at `/openapi.yaml`, with release-packaged static assets, endpoint tests, README
links, and approved feature-spec status. Existing API routes and contract were
not changed.

## Evidence and decisions

- Vendored Swagger UI 5.11.10 generated `dist` assets from the tagged GitHub
  source archive; archive and asset provenance/checksums are recorded in
  `priv/static/swagger/ASSET-SOURCE.md`.
- The upstream `Swagger-UI-LICENSE.txt` is bundled beside the assets.
- Versioned asset names plus conservative `no-cache` ETag responses avoid stale
  browser assets while the unversioned HTML and OpenAPI response remain
  non-cacheable.
- `priv/static` is already copied into the Mix release/Docker build; the OpenAPI
  file is copied there from the repository source and parity-tested.
- The OpenAPI server URL is `/`, so Swagger UI resolves Try it out requests
  against the host serving the documentation in native, Docker, and Kind-style
  deployments.
- Asset paths are resolved with `Application.app_dir/2` per request rather than
  compiled into module attributes, keeping releases relocatable.
- All packaged-file read failures are logged with fixed asset identifiers and
  internal paths, then translated to the same plain HTTP 500 response.
- The checksum test verifies all three generated assets and the upstream license
  file against the provenance metadata.
- Browser verification found Swagger UI's default remote validator request to
  `https://validator.swagger.io`; `validatorUrl: null` is now explicit in the
  bundled configuration, with source and runtime smoke assertions preventing
  its return.

## Verification journal

Completed checks: `mix format --check-formatted`,
`mix compile --warnings-as-errors`, and `mix test` (76 passed); `MIX_ENV=prod
mix release`; pinned Redocly OpenAPI lint (valid, with the two pre-existing
4XX-response warnings); `docker compose up -d --build`; and the bounded
`script/swagger_smoke.sh` against the built release image with PostgreSQL,
covering readiness, HTML, all assets, content types, cache policy, OpenAPI byte
parity, relative server URL, and a representative obtain request. `docker
compose config`, shell syntax, release/image asset presence, and `git diff
--check` also passed. The GitHub Actions smoke step uses the same script and
existing PostgreSQL service with a 60-attempt readiness bound. Secret scan found
no private-key or cloud-key patterns in changed authored files; the upstream
license notice is bundled. Maintained browser acceptance after the validator fix
confirmed six operations rendered with schemas/examples, Execute enabled, a
same-origin 200 response with `{"holder": null}`, all network requests
same-origin, and no validator request. Acceptance verification marked all eight
criteria accepted. Final general, security, and performance reviews approved the
implementation. This journal is final for issue #24 and pending merge.
