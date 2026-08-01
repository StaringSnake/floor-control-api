# Run journal: local Kind Kubernetes manifests (2026-08-01)

## Status

**Active — pending final external review.** This delegated run implements issue
#20 only; Kind build/load and cleanup automation remain issue #21. Static
validation and a complete clean Kind lifecycle passed after Docker Desktop was
authorized and configured to 4096MiB.

## Decisions and invariants

- `deploy/kind/` is a foundation-only kustomization with separate migration and
  application kustomizations; no committed Secret exists.
- PostgreSQL is a one-replica StatefulSet using a pinned PostgreSQL 16.4 image,
  a static hostPath PV, and a bound 1Gi PVC. The one-node workflow supplies the
  scheduling constraint; the PV has no cluster-name-specific node affinity.
- The API is exactly one replica with `Recreate`, NodePort `30080`, non-root
  security controls, bounded resources, and `/`/`/ready`/startup probes.
- The migration Job and API use the same local placeholder tag. The Job explicitly
  runs Ecto migrations; the API explicitly runs `start`, bypassing the image
  entrypoint migration step.
- The current local image is the mutable placeholder `floor-control-api:kind-local`;
  issue #21 must render one immutable `kind-<git-sha>` tag for both workloads.
- `DATABASE_SSL=false` is confined to this private local in-cluster network.
- The shared ConfigMap sets local-only `ERL_AFLAGS` to `+S 2:2 +SDcpu 1 +SDio 1`.
  This bounds the demo VM's BEAM scheduler footprint and is not a production
  recommendation.
- PostgreSQL uses a short-lived root init container with only `CHOWN` and
  `FOWNER` to assign the auto-created hostPath directory to UID/GID `999:999`;
  the database container remains non-root with all capabilities dropped, a
  read-only root filesystem, and writable `/tmp` and `/var/run/postgresql`
  emptyDirs.
- Image-native identity was measured with `docker run --rm --entrypoint id
  floor-control-api:kind-local app`: `uid=100(app) gid=101(app)`. The API and
  migration manifests use those numeric IDs rather than relying on the image's
  nonnumeric username.
- Pinned PostgreSQL identity was measured with `docker run --rm --entrypoint id
  postgres:16.4-bookworm@sha256:e62fbf9d3e2b49816a32c400ed2dba83e3b361e6833e624024309c35d334b412
  postgres`: `uid=999(postgres) gid=999(postgres)`.

## Changed paths

- `deploy/kind/` manifests and direct lifecycle README
- `docs/adr/0001-kind-static-hostpath-persistence.md`
- approved spec updated to reflect issue #20/#21 boundary
- this journal; the assessment journal remains preserved

## Validation

- `kubectl kustomize deploy/kind`, `deploy/kind/migration`, and
  `deploy/kind/application` (kubectl v1.21.5): passed; foundation renders only
  long-lived prerequisites and the other kustomizations render their separate
  lifecycle resources.
- Rendered foundation kinds were exactly `Namespace, ServiceAccount, ConfigMap,
  Service, PersistentVolume, PersistentVolumeClaim, StatefulSet`; migration
  rendered only `Job`; application rendered only `Service,Deployment`.
- ConfigMap semantic check passed: settings are under `data` and the rendered
  `configMapKeyRef`/`envFrom` references resolve to declared keys.
- Ruby YAML stream parse for all manifest files: passed.
- `git diff --check`, `mix format --check-formatted`, and the secret-looking
  literal scan: passed.
- `docker build --tag floor-control-api:kind-local .`: passed. The local
  placeholder tag is not treated as a registry digest; #21 must replace it
  with an immutable `kind-<git-sha>` tag when rendering.
- Image-native identity: `docker run --rm --entrypoint id
  floor-control-api:kind-local app` returned `uid=100(app) gid=101(app)`.
- `ERL_AFLAGS` was empirically honored by the Mix release. A temporary Docker
  process with `ERL_AFLAGS='+S 2:2 +SDcpu 1 +SDio 1'` showed:
  `/app/erts-14.2.5.15/bin/beam.smp -S 2:2 -SDcpu 1 -SDio 1`, with measured
  memory `49MiB / 1.939GiB` for the sleeping demo VM.
- Pinned PostgreSQL Docker check passed with read-only root plus writable `/tmp`
  and `/var/run/postgresql` mounts; the data directory remained writable across
  container restart. The StatefulSet now checks root ownership with `stat`,
  skips recursive `chown` for `999:999`, and sets `fsGroupChangePolicy:
  OnRootMismatch`.
- Rendered Job/API image equality check passed: both resolve to
  `floor-control-api:kind-local`.
- API direct-container check passed with read-only root, `/tmp` tmpfs, explicit
  migration eval, explicit `start`, and the local scheduler bounds.
- README shell blocks passed `sh -n` syntax validation; `shellcheck` was not
  installed.
- Secret ordering/reuse review passed: Namespace precedes Secret creation;
  existing Secret is reused; generated values use protected temporary files and
  `--from-file`, with trap cleanup.
- Fixed-name migration Job lifecycle finding resolved: an active Job is waited on
  with a bounded 300-second completion wait and failure stops the lifecycle;
  after a wait failure, only a terminal Job condition with
  `.type=="Failed"` and `.status=="True"` permits deletion. Active, unknown, or
  timed-out Jobs are not deleted. A permitted completed/failed Job is deleted
  with `--ignore-not-found --wait=true`, the current migration kustomization is
  applied, and completion is awaited before applying the API. This guarantees
  pending Ecto migrations are checked on every deployment without inferring
  terminal state from pod failure counts or blindly deleting active work.
- PostgreSQL security now explicitly uses root only for the narrow ownership init
  (`runAsUser: 0`, `runAsNonRoot: false`) and the image-native database identity
  (`runAsUser/runAsGroup: 999`).
- `MIX_ENV=test mix ecto.setup && MIX_ENV=test mix test`: passed, 76 tests.
- Docker Desktop settings were verified at
  `~/Library/Group Containers/group.com.docker/settings.json`; only
  `memoryMiB` changed from `2048` to `4096`. A backup was saved outside the
  repository. Docker reported `MemTotal=4125036544` bytes after graceful
  restart.
- Existing unrelated containers `floor-control-api-api-1` and
  `floor-control-api-db-1` were stopped by the authorized Docker restart,
  explicitly restarted afterward, and returned healthy. No unrelated data or
  containers were deleted.
- Previous baseline: unrestricted migration `beam.smp` reached approximately
  1.23GiB RSS and was globally OOM-killed. The final run verified inherited
  `ERL_AFLAGS` on the release process and kept the Job under its 512Mi limit.
- `kubectl apply --dry-run=client --validate=false -k` passed for foundation,
  migration, and application while the temporary cluster was available.
- `kubectl apply --dry-run=server --validate=true -k` passed for all three
  kustomizations while the temporary cluster was available.
- A post-cleanup client dry-run was attempted again and could not complete
  because no Kubernetes API server is configured (`localhost:8080` refused);
  Kustomize/Ruby semantic validation remains the available offline check.
- PostgreSQL reached `1/1 Running` and its PVC reached `Bound` in the prior
  successful v1.31.4 cluster run. The original
  PostgreSQL digest had one extra `9`; correcting it to
  `sha256:e62fbf9d3e2b49816a32c400ed2dba83e3b361e6833e624024309c35d334b412`
  allowed the image to pull. The initial hostPath ownership assumption failed;
  adding the narrowly-capable init container made PostgreSQL start.

A disposable Kind run was attempted with a temporary, non-global binary:

- URL: `https://github.com/kubernetes-sigs/kind/releases/download/v0.32.0/kind-darwin-amd64`
- Checksum URL: `https://github.com/kubernetes-sigs/kind/releases/download/v0.32.0/kind-darwin-amd64.sha256sum`
- SHA-256: `295ac6d0d634c9819c9907df45e3017d1f13166bd13c3404c45e79f7faa47498`
- Kind: `v0.32.0 go1.26.3 darwin/amd64`
- Successful node image: `kindest/node:v1.31.4`, digest
  `sha256:2cb39f7295fe7eafee0842b1052a599a4fb0f8bcf3f83d96c7f4864c357c6c30`.

The prior unrestricted run had a 1.23GiB BEAM RSS/global OOM failure under the
2GiB VM. After the 4GiB allocation and inherited scheduler bound, the clean
`floor-control` run completed:

- Kind `v0.32.0 go1.26.3 darwin/amd64`; Kubernetes `v1.31.4`.
- Node image `kindest/node:v1.31.4@sha256:2cb39f7295fe7eafee0842b1052a599a4fb0f8bcf3f83d96c7f4864c357c6c30`.
- API image `floor-control-api:kind-local` built, loaded into node containerd,
  and rendered identically for Job/API.
- Namespace created first; Secret generated through mode-700/600 temporary files
  and `--from-file`, with no values logged.
- Client and server dry-runs passed for all three kustomizations.
- PVC was `Bound` to `postgres-data`; PostgreSQL was ready.
- Data-root ownership was `999:999`; read-only root with writable `/tmp` and
  `/var/run/postgresql` operations passed.
- Migration Job completed with `succeeded=1`, zero restarts/OOM, 512Mi limit, and
  four `schema_migrations` rows.
- API Deployment was exactly one ready replica using explicit `start`; API logs
  contained no entrypoint migration output.
- Loopback port-forward returned HTTP 200 for `/`, `/ready`, `/swagger`, and
  `/openapi.yaml`.
- A representative floor holder survived PostgreSQL Pod deletion/recreation;
  PVC remained `postgres-data:Bound` and API readiness recovered.
- Fixed-name migration Job was deleted/recreated and completed again; schema
  migration count remained `4/4`.
- API Pod deletion produced exactly one replacement ready Pod; a newly-created
  holder remained readable after replacement.
- NodePort `30080` returned readiness from a Docker client inside the Kind node
  interface. Host loopback mapping remains issue #21 responsibility.
- Temporary cluster, namespace, port-forward, Secret, binary, and files were
  cleaned up. Unrelated Compose containers were left healthy.

## Final review and acceptance

- General engineering review: **APPROVE**.
- Security review: **APPROVE**; no committed Secret, local-only SSL exception,
  narrow root ownership init, one replica, and explicit placeholder-image/
  NodePort/#21 boundaries reviewed.
- Performance/container review: **APPROVE**; 4GiB Docker allocation and BEAM
  scheduler bounds resolved the measured 2GiB OOM; resource limits remain
  bounded.
- Acceptance verification: **ACCEPT**; clean Kind lifecycle, migration,
  persistence, rerun, replacement, probes, Swagger/OpenAPI, and NodePort
  evidence completed.
- Status: **pending merge**.

## Risks and follow-up

The self-review dispositions are: ConfigMap data fixed; lifecycle split into
foundation/migration/application fixed; local image tag semantics documented;
cluster-name node affinity removed; hostPath ownership verified and fixed with a
minimal init container; PostgreSQL image digest corrected; local BEAM scheduler
 limits added to address the measured OOM; credential reuse and secure temporary
 file handling documented; PostgreSQL read-only-root mounts and O(1) ownership
 check documented; fixed-name Job recreation lifecycle corrected. Issue #21 must
 generate/reuse the Secret ephemerally,
render/load one exact immutable `kind-<git-sha>` tag for both Job and API,
delete/recreate failed migration Jobs, and wait for Job completion before
applying the API kustomization.
