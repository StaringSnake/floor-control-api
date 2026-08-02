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

### Local Kind deployment

This is a disposable, local-only demo deployment. It requires Docker with at
least 4 GB allocated memory, Kind, kubectl, OpenSSL, curl, git, and `pgrep`.
Run the lifecycle scripts from the repository root. The create script requires
the image and Kind manifest inputs to be committed, then builds the current
`HEAD`, loads the immutable `floor-control-api:kind-<git-sha>` image into Kind,
runs the migration Job, and starts exactly one API replica:

```sh
scripts/create-and-deploy-in-kind.sh
curl --fail http://127.0.0.1:4000/ready
scripts/verify-kind-deployment.sh
```

The script prints API, Swagger, OpenAPI, status, and log commands. The default
loopback mapping is `127.0.0.1:4000` (NodePort `30080`); Compose also uses port
4000, so stop Compose or choose a free port:

```sh
KIND_HOST_PORT=4001 scripts/create-and-deploy-in-kind.sh
KIND_HOST_PORT=4001 scripts/verify-kind-deployment.sh
```

The lifecycle scripts do not modify the user's kubeconfig. For inspection,
create a protected standalone kubeconfig and remove it when finished:

```sh
(
  set -eu
  inspect_dir="$(mktemp -d "${TMPDIR:-/tmp}/floor-control-kind-inspect.XXXXXX")"
  chmod 700 "$inspect_dir"
  trap 'rm -rf -- "$inspect_dir"' EXIT
  inspect_cluster="${KIND_CLUSTER:-floor-control}"
  inspect_namespace="${KIND_NAMESPACE:-floor-control}"
  inspect_host_port="${KIND_HOST_PORT:-4000}"
  inspect_context="kind-${inspect_cluster}"
  inspect_kubeconfig="$inspect_dir/kubeconfig"
  kind get kubeconfig --name "$inspect_cluster" >"$inspect_kubeconfig"
  chmod 600 "$inspect_kubeconfig"
  kubectl --kubeconfig "$inspect_kubeconfig" --context "$inspect_context" \
    -n "$inspect_namespace" get pods,job,pvc
  kubectl --kubeconfig "$inspect_kubeconfig" --context "$inspect_context" \
    -n "$inspect_namespace" logs deployment/floor-control-api
  kubectl --kubeconfig "$inspect_kubeconfig" --context "$inspect_context" \
    -n "$inspect_namespace" logs job/floor-control-migrate
  curl --fail "http://127.0.0.1:${inspect_host_port}/"
  curl --fail "http://127.0.0.1:${inspect_host_port}/swagger"
  curl --fail "http://127.0.0.1:${inspect_host_port}/openapi.yaml"
)
```

The script creates `floor-control-secrets` once using protected temporary
files, prints no credential values, and reuses the managed Secret and PVC on
reruns. Do not rotate the Secret during a normal rerun; password rotation
requires a coordinated PostgreSQL operation. The immutable image tag is
rebuilt and loaded for each committed `HEAD`; the migration Job is retained
when that exact image already completed and is recreated for an older or
terminal-failed Job. Active, unknown, or timed-out Jobs are not deleted
automatically. Inspect status/logs and resolve the reported condition before
retrying a failed deployment.

PostgreSQL data survives Pod recreation but is intentionally lost when the
Kind cluster is deleted. Deletion is explicit and destructive:

```sh
KIND_CLUSTER=floor-control scripts/delete-kindly.sh
```

The delete script refuses a same-name cluster without the Floor Control
ownership marker, removes only that cluster and its local data, and is safe to
run again when the cluster is already absent. If creation or deletion times
out, inspect the reported named cluster, verify ownership, and retry; do not
delete an unfamiliar cluster. `KIND_CLUSTER`, `KIND_NAMESPACE`,
`KIND_HOST_PORT`, `KIND_NODE_PORT`, and digest-pinned `KIND_NODE_IMAGE` can be
overridden; see [`deploy/kind/README.md`](deploy/kind/README.md) for details.

Kind is not production: it uses one node, local hostPath persistence,
in-cluster PostgreSQL without production backup/failover, and one API replica
because timeout coordination is not distributed. Keep secrets and
environment-specific values outside the repository and image. For
troubleshooting/recovery, start with the printed status and log commands,
preserve active migration Jobs, and retry only after the failing condition is
understood.

### API endpoints

The API contract and interactive documentation are available without internet
access:

| Endpoint | Purpose |
| --- | --- |
| `GET /` | Liveness |
| `GET /ready` | Database-aware readiness |
| `GET /groups/{groupId}/floor` | Current floor holder lookup |
| `POST /groups/{groupId}/floor` | Obtain a floor |
| `DELETE /groups/{groupId}/floor/{userId}` | Release a floor |
| `GET /groups/{groupId}/floor/history` | Floor history |
| `GET /swagger` | Bundled interactive Swagger UI |
| `GET /openapi.yaml` | Raw OpenAPI contract |

Open [Swagger UI](http://localhost:4000/swagger) to try same-origin requests, or
download the raw [OpenAPI contract](http://localhost:4000/openapi.yaml). The
contract uses a server-relative URL, so Try it out targets the host serving the
documentation rather than a hard-coded development host. These links use the
same host and port for native development, Docker Compose, and a future Kind
port-forward or NodePort address.

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
