# Run journal: README and Kind assessment (2026-08-01)

## Verdict

- **README for supported Compose/native workflows: Yes, sufficient.** It gives
  prerequisites and commands (`README.md:8-44`), configuration and secret/TLS
  boundaries (`README.md:46-55, 68-82`), migration behavior
  (`README.md:84-87`), probes and the one-instance limitation
  (`README.md:57-66`), and verification commands (`README.md:89-113`).
- **Image technically Kubernetes-compatible: Yes, qualified.** The image is a
  pinned multi-stage build, runs as non-root, listens on configurable `PORT`,
  and has a database-aware `/ready` check (`Dockerfile:2-3, 24-45`; routes at
  `lib/floor_control_web/router.ex:8-15`). Kubernetes will not use the Docker
  `HEALTHCHECK` automatically; probes must be declared in a workload.
- **Turnkey Kind support in this repository: No.** There are no Kubernetes,
  Kind, or Helm assets; repository YAML/JSON files are only `docker-compose.yml`
  and `OpenApiSpec.yaml`. Compose supplies only a named Postgres volume
  (`docker-compose.yml:1-14`), not a Kubernetes persistence or service model.

## Minimum one-replica Kind checklist

1. Build the pinned `Dockerfile`, then make the image available to Kind (for
   example, `kind load docker-image`), or publish it to a registry accessible
   by the cluster. Use an immutable tag; no image-loading or registry workflow
   exists today.
2. Add a one-replica Deployment and ClusterIP Service, with container port
   `4000` (or an explicitly coordinated `PORT`). Add HTTP liveness `/` and
   database-aware readiness `/ready`; use startup/readiness timing that allows
   migration and Postgres startup. The image entrypoint runs migrations before
   `start` (`docker-entrypoint.sh:1-5`).
3. Provide `DATABASE_URL` and `SECRET_KEY_BASE` through a Kubernetes Secret;
   provide non-secret `PHX_HOST`, `PORT`, `POOL_SIZE`, `FLOOR_TIMEOUT_SECONDS`,
   and `DATABASE_SSL` through a ConfigMap or explicit deployment config. Do not
   copy `.env.example` values into a cluster (`.env.example:1-21`).
4. Supply Postgres separately as a managed/external service, or add a
   Postgres StatefulSet, Service, Secret, and PVC/storage class. A Pod without
   durable Postgres storage is not a safe deployment; a PVC alone does not
   provide backup/restore.
5. For the production default `DATABASE_SSL=true`, mount a CA certificate from
   a Secret and set `DATABASE_CA_CERT_FILE` and
   `DATABASE_SSL_SERVER_NAME`; startup rejects missing values or CA files
   (`config/runtime.exs:15-51`). For an isolated local Kind network,
   `DATABASE_SSL=false` is an explicit, qualified choice, not a production
   default.
6. Treat entrypoint migrations as a one-replica bootstrap convenience, not a
   concurrency-safe migration controller. Keep replicas at one for this
   application and preferably run migrations as a separately ordered one-shot
   Job before the Deployment; if retaining the entrypoint, verify Ecto migration
   locking and failure/retry behavior. Migration code is under
   `priv/repo/migrations/`, and `Release.migrate/0` runs all pending migrations
   (`lib/floor_control/release.ex:4-9`).

## Blockers and operational risks

- No Deployment/Service/Secret/ConfigMap/PVC/StatefulSet/Job, Kind config,
  image loading instructions, or Helm chart is present.
- Postgres persistence, credentials, and recovery are deployment decisions;
  defaulting to an ephemeral database would lose state. TLS CA material must
  remain outside source and images.
- `/ready` depends on `SELECT 1` with one-second query/pool timeouts
  (`lib/floor_control/health.ex:9-17`), so it correctly gates traffic but may
  flap during database startup. `/` is liveness (`health_controller.ex:4-15`).
- `FloorControl.FloorTimeout` is a named singleton GenServer started in the
  supervision tree (`lib/floor_control/application.ex:6-14`; singleton name at
  `lib/floor_control/floor_timeout.ex:35-38`). The README explicitly says only
  one application instance is supported (`README.md:59-62`); do not scale out
  until cross-instance coordination/ownership semantics are designed.

## Git evidence

Before creating this journal, `git status --short --branch` reported a clean
working tree on `main` tracking `origin/main`. After creating it, the only
expected change is this new journal path; no application, deployment, README,
or other file was edited. No Kind cluster was run and no commit/push was made.
