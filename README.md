# Floor Control API

Bootstrap repository for the Motorola Floor Control API challenge.

- Challenge brief: [REQUIREMENTS.MD](REQUIREMENTS.MD)
- API contract: [OpenApiSpec.yaml](OpenApiSpec.yaml)

## Local development

Requirements: Docker with Compose v2 for the containerized workflow. The Mix
project declares Elixir `~> 1.14`; CI verifies the repository with Elixir 1.16
and Erlang 26, PostgreSQL 16, and the pinned Hex and Rebar versions (2.5.1 and
3.25.1).

```sh
cp .env.example .env
# Replace SECRET_KEY_BASE with a locally generated random value.
docker compose up --build
```

The API is available at <http://localhost:4000/> by default. If `.env` sets a
different `PORT`, use `http://localhost:${PORT}/` with `${PORT}` replaced by the
configured value. PostgreSQL is persisted in the `postgres_data` Compose volume.
Stop the stack with `docker compose down`; add
`-v` when intentionally removing the local database.

### Native development

For a host-based workflow, start PostgreSQL and configure `DATABASE_HOST`,
`DATABASE_USER`, `DATABASE_PASSWORD`, and `DATABASE_NAME` (the development
defaults are `localhost`, `postgres`, `postgres`, and `floor_control_dev`). Then
run:

```sh
mix setup
mix ecto.setup
mix phx.server
```

`mix setup` fetches dependencies only. `mix ecto.setup` creates the database and
runs all migrations. To apply migrations later, use `mix ecto.migrate`. The server
listens on port 4000 by default. Native development uses the development
configuration and its non-production secret; do not use it as a production
configuration.

### Configuration

The Compose example is configured through `.env` (copy `.env.example` first).
`POSTGRES_DB`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` configure PostgreSQL;
`DATABASE_URL` configures the API connection; `SECRET_KEY_BASE` is required;
`PHX_HOST`, `PORT`, `POOL_SIZE`, and `FLOOR_TIMEOUT_SECONDS` are optional runtime
settings; and `DATABASE_SSL` selects database TLS. Production also requires
`DATABASE_CA_CERT_FILE` and `DATABASE_SSL_SERVER_NAME` when TLS is enabled.
Supply production values through the deployment environment or secret/config
mechanism; do not commit them or certificate material.

Occupied floors are automatically released after `FLOOR_TIMEOUT_SECONDS` (default
30 seconds). Timeout recovery is supervised and uses persisted ownership rows, so
it also recovers expired ownerships after a restart. This deployment currently
supports one application instance only; there is no cross-instance coordinator.
The bounded background sweep runs at half the timeout, capped at 60 seconds, so
automatic release may occur within that sweep granularity after the timeout.

`/` is a liveness check and `/ready` is a database-aware readiness check. The
container health check uses `/ready`, so a running API with an unavailable
database is reported unhealthy even though its liveness endpoint remains up.

The production image runs the release startup command. It waits for PostgreSQL
through Compose's health dependency and runs `FloorControl.Release.migrate/0`
before starting the server. Runtime secrets and connection details are supplied
through the environment; they are not stored in the image. Compose explicitly
sets `DATABASE_SSL=false` because its database uses a private local network. The
production runtime defaults `DATABASE_SSL=true`; production deployments must
provide a PostgreSQL TLS endpoint and may override this only for a trusted,
explicitly documented private network.

When `DATABASE_SSL=true`, production must provide `DATABASE_CA_CERT_FILE` (a
mounted trusted CA certificate file) and `DATABASE_SSL_SERVER_NAME` (the
PostgreSQL certificate hostname). Startup fails if either value is missing or
the CA file does not exist. The connection uses peer and hostname verification.
These values and certificate material must be supplied by the deployment
environment and must not be committed.

The container entrypoint runs `FloorControl.Release.migrate/0` before starting
the server, so `docker compose up --build` applies pending migrations
automatically. A later image deployment reruns the migration command safely
before serving traffic.

## Verification

```sh
docker compose config
docker build --tag floor-control-api:local .
docker run --rm -v "$PWD:/work:ro" redocly/cli:1.25.13@sha256:5ba4171da3ef3b17c855358b00858c93d7efdea0539815b486ac7c7bfe57e18b lint --skip-rule security-defined --skip-rule info-license --skip-rule no-server-example.com /work/OpenApiSpec.yaml
```

CI runs formatting, compilation, tests against PostgreSQL, and the same pinned
OpenAPI validator. The build bootstrap pins Hex 2.5.1 and Rebar 3.25.1; Rebar
is downloaded with a SHA-512 check before use.

The equivalent local checks are:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix ecto.setup
MIX_ENV=test mix test
```

`MIX_ENV=test mix ecto.setup` targets the configured test database and should
not be run against a shared database. `mix test` uses PostgreSQL and the SQL
Sandbox configured for tests. OpenAPI validation, the production image build,
and Compose configuration are covered by the Docker commands above and by CI.
