# Run journal: local Kind Kubernetes manifests (2026-08-01)

## Status

**Completed for implementation verification and reviews — pending commit/merge.** Issue #20 was merged in
`39182df` (PR #26). This run adds the scripted immutable-image Kind lifecycle;
the full README documentation remains issue #22. Static validation and the
prior complete clean Kind lifecycle passed with Docker Desktop configured to
4096MiB.

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
- Issue #21 scripts use `floor-control-api:kind-<committed-sha>`, reuse the
  existing Secret/PVC, require a loopback-only Kind mapping, and delete only a
  named cluster through `delete-kindly.sh`.
- The corrected automation validates Docker memory at 4,000,000,000 bytes,
  rejects dirty image/manifest inputs including untracked files, uses a
  temporary kubeconfig, validates one pinned control-plane node, and supports
  a configurable NodePort/host port without disturbing Compose on port 4000.
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
- `scripts/create-and-deploy-in-kind.sh`, `scripts/delete-kindly.sh`, and
  `scripts/verify-kind-deployment.sh`, and `scripts/test-kind-scripts.sh`
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

Issue #21 automation status: **pending review**. The acceptance helper covers
loopback endpoints, one ready API replica, immutable image equality, migration
Job completion/no-op same-image rerun, Secret UID reuse, API replacement, and
PostgreSQL Pod persistence. Static/preflight checks are available, but full
clean-cluster execution remains dependent on the local Docker/Kind environment.

The corrected review pass used the approved temporary Kind v0.32.0 Darwin amd64
binary (SHA-256
`295ac6d0d634c9819c9907df45e3017d1f13166bd13c3404c45e79f7faa47498`) with
`KIND_HOST_PORT=4001`. Docker reported 4,125,036,544 bytes, six CPUs, and
cgroup v1. The Kind node image was pulled and the node container exposed only
`127.0.0.1:4001->30080`; however, Kind remained at `Starting control-plane`
while `kubeadm init` was still running until the bounded verification command
was stopped. The disposable cluster was removed with `delete-kindly.sh`; the
second deletion was idempotent and no other clusters existed. No API, Secret,
migration, or endpoint acceptance evidence was claimed. Compose API/DB
containers remained healthy on API port 4000 throughout.

Bash/sh syntax, deterministic preflight tests, custom namespace and
immutable-tag rendering, Kustomize rendering, diff checks, and secret scans
passed. The current kube context remained unset because the lifecycle did not
reach its temporary kubeconfig export. The DB is intentionally not published
to host port 5432, so the default test configuration cannot reach it from the
host; isolated connectivity was used for the test suite below.

After reproducing the unbounded Kind startup, the create script now runs Kind
creation with a configurable bounded supervisor (`KIND_CREATE_TIMEOUT_SECONDS`,
default 300, allowed range 60..900) and reports the retained target cluster for
safe inspection. A clean retry with the earlier 180-second setting returned the
explicit timeout after 183 seconds; it was then deleted and verified absent. An isolated temporary
PostgreSQL container was bound only to host `127.0.0.1:5432` (Compose's DB has
no host binding), `MIX_ENV=test mix ecto.setup && MIX_ENV=test mix test` passed
all 76 tests, and the temporary database was removed. Compose API/DB remained
healthy on port 4000.

## Runtime recovery evidence (issue #21 follow-up)

Docker Desktop was gracefully quit and reopened through the previously
authorized macOS mechanism. The daemon returned in 17 seconds with the same
`Mem=4125036544`, `CPUs=6`, `Cgroup=1`, and Docker 20.10.10 settings. Compose
containers were recreated with `docker compose up -d` and returned healthy on
port 4000. An empty stale `kind` Docker network was removed; no volumes or
Compose data were touched.

The temporary Kind v0.32.0 binary was downloaded again and matched the official
SHA-256 above. A clean script run initially reached the control plane, built
and loaded `floor-control-api:kind-39182dfe766032d019b12ba24e032dc3c66a105b`,
and exposed `127.0.0.1:4001->30080`. The run found and corrected three proven
script defects: source `kustomization.yaml` was being recopied over the
immutable-tag rewrite; `kubectl wait --for=condition=Bound` is unsupported for
PVC phase in the repository's kubectl and was replaced by bounded phase
polling; and the generated `DATABASE_URL` had a trailing newline, producing
the observed database name `floor_control\n`. Context restoration was also
added because `kind create` itself writes `kind-floor-control` to the user's
kubeconfig.

After those fixes, the migration log reached the actual root cause before the
next clean Kind attempt: the existing Secret was generated with the newline
database URL. The corrected Secret generation was then exercised on a clean
cluster. A subsequent clean Kind run failed in Kind's own `kubeadm init` after
approximately 257 seconds; the direct checksum-pinned Kind command with the
same generated configuration and `--wait 600s` independently failed after
approximately four minutes with:

`The kubelet is not healthy ... required cgroups disabled` and
`[api-check] The API server is not healthy after 4m0s`.

This isolates the remaining blocker to the Docker Desktop cgroup-v1/Kind
control-plane environment rather than the script timeout wrapper. The target
cluster was deleted, no Kind clusters remain, and Compose API/DB stayed healthy.
Issue #21 remains **pending review**; no full endpoint, rerun, persistence, or
delete acceptance claim is made from this follow-up.

## Runtime acceptance retry (2026-08-02)

The installed `/Users/andreramos/go/bin/kind` was verified as v0.32.0
Darwin/amd64. Docker reported 29.6.2, 8,321,458,176 bytes, 12 CPUs,
`cgroupfs`, cgroup v2; Compose API/DB were brought up healthy on port 4000.
The first clean create reached a healthy control plane but exposed the proven
repository-kubectl incompatibility `create secret generic: unknown flag:
--label`. The narrow fix creates the Secret from protected files, then applies
its ownership labels with `kubectl label`.

With `KIND_HOST_PORT=4001`, the supported create script then completed.
Independent checks passed for `127.0.0.1:4001`, the exact pinned node digest
`sha256:2cb39f7295fe7eaf0842b1052a599a4fb0f8bcf3f83d96c7f4864c357c6c30`, the
full Git-SHA image tag, loaded containerd image, Bound PVC, ready PostgreSQL,
one ready API replica, completed migrations, and HTTP 200 for `/`, `/ready`,
`/swagger`, and `/openapi.yaml`. The current kube context remained unset.

The acceptance helper initially exposed a transient API recovery window after
PostgreSQL Pod replacement: the database marker was present in PostgreSQL but
the first HTTP read returned 500. The helper now retries bounded readiness and
marker reads; the complete helper then passed API replacement, PostgreSQL Pod
persistence, endpoint, Secret, image, and replica checks. A direct rerun before
the same-image no-op refinement showed Secret UID unchanged and migration Job
UID changed as the prior always-rerun lifecycle intended. The current script
now retains a completed migration Job when its immutable image is unchanged,
and only recreates it for a failed or older-image Job. The final same-image
no-op behavior was exercised by the completed helper run.

The port and node-image mismatch guards rejected safely without changing the
cluster, PVC, or Secret. The target cluster was deleted twice successfully;
port 4001 was free, no Kind cluster/node remained, and Compose stayed healthy.
The named `floor-control` cluster was deleted with `delete-kindly.sh`; a second
deletion was idempotent, no Kind clusters remained, port 4001 was free, and
Compose API/DB remained healthy. Issue #21 runtime acceptance is complete for
this retry; only external review/merge remains.

## Aggregated review dispositions

- **A kubeconfig safety:** fixed with a protected temporary `KUBECONFIG` passed
  to Kind from creation through inspection; verify now exports its own protected
  kubeconfig. Help/preflight sentinel byte-identity and early temp cleanup are
  executable tests.
- **B input/Secret trust:** fixed with strict verify validation, managed-by and
  part-of labels, required-key checks, and rejection of unowned pre-automation
  Secrets.
- **C PV collision:** fixed by rejecting a `postgres-data` claimRef reserved by
  another namespace before mutation.
- **D bounded operations:** fixed with configurable bounded Kind creation,
  bounded cluster deletion, 30-second migration Job delete requests, and
  existing long-watch timeouts preserved.
- **E performance:** same-HEAD image build/load remains conservative because
  Docker image IDs and node containerd identities are not treated as equivalent
  without an explicit portable proof; correctness takes precedence.
- **F behavioral coverage:** deterministic fake-command tests now execute same,
  old, failed, active, and timed-out migration Job branches; PV collision,
  Secret ownership rejection, early kubeconfig cleanup, and bounded deletion.
  Full runtime coverage remains blocked by intermittent Docker cgroup-v1 kubelet
  initialization.

### Final review defects (2026-08-02)

- **Verify temporary files:** fixed. `verify-kind-deployment.sh` now creates one
  mode-700 temporary directory before the cleanup trap and uses it for the
  kubeconfig; the executable test forces failure after kubeconfig creation and
  confirms no matching directory or file remains.
- **Process-tree timeout:** fixed. Create and delete now share a bounded,
  process-tree-only supervisor: it captures descendants rooted at the launched
  child, sends TERM, checks liveness during bounded grace, sends KILL to any
  remaining captured PIDs, and reaps the launched child without process-group
  termination. The executable test uses a child that ignores TERM and confirms
  timely return with no surviving descendant.
- **Validation:** Bash/sh syntax, executable fake-command tests, Kustomize
  rendering, `git diff --check`, and the repository secret scan passed. No Kind
  runtime retry was performed for this review pass.
- **General-review test gap:** fixed. The executable verify test now uses only
  fake `kind` and `kubectl` fixtures: fake Kind emits a recognizable
  kubeconfig, fake kubectl fails the initial Secret lookup, and the test asserts
  that lookup occurred and the isolated mode-700 temp directory/kubeconfig were
  removed. The former restricted-PATH prerequisite assertion was removed.

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

## Aggregated review follow-up (2026-08-02)

Review selection: all six actionable findings were selected for fix and
deterministic coverage; no finding was rebutted. The ownership boundary is a
Kubernetes `kube-system/floor-control-kind-ownership` ConfigMap containing the
exact cluster name, marker version, and `floor-control-kind` manager label.
Create writes it only after a new cluster reaches the API; create reruns and
delete require an exact marker and refuse same-name unowned clusters. This uses
the repository's existing Kind/kubectl/Docker lifecycle and performs no
destructive action before ownership validation.

Dispositions:

- Delete now uses a mode-700 temporary directory and isolated kubeconfig for
  discovery, marker validation, and deletion; the user's kubeconfig is not
  read or written. Log cleanup is covered by the exit and signal trap.
- Secret generation now creates a client-side manifest, labels it locally, and
  applies only the labeled manifest. Pipeline failure is explicit, so a label
  failure cannot create an unlabeled Secret.
- `KIND_NODE_IMAGE` overrides must match `name@sha256:<64 hex>`; mutable tags and
  newline-containing values are rejected before any Docker/Kind operation.
- Create and delete track active child PIDs and terminate/reap their process
  trees on INT/TERM as well as bounded timeout. Host crash or unavoidable
  SIGKILL remains outside shell cleanup guarantees.

Deterministic coverage passed in `scripts/test-kind-scripts.sh`: kubeconfig byte
preservation, owned/unowned marker paths, mutable image rejection, atomic
Secret label-failure behavior, bounded descendant cleanup, and interrupted
delete cleanup. Bash syntax, Kustomize rendering, YAML parsing, secret-looking
literal scan, and `git diff --check` also passed.

Runtime verification was performed because the create marker and atomic Secret
path are lifecycle changes. A clean `KIND_HOST_PORT=4001` create and the
existing acceptance helper passed; the marker was observed with exact ownership
values, endpoints and persistence checks remained successful, and same-image
Secret/Job reuse remained successful. The named cluster was deleted, deletion
was repeated idempotently, no Kind clusters remained, and Compose API/DB stayed
healthy with HTTP 200 on port 4000 before and after. Current outcome: issue #21
review findings resolved; commit/merge remains.

## Final review verdicts

- General review: **APPROVE — no findings**.
- Security review: **APPROVE — no findings**; selected for Secret handling,
  ownership markers, input validation, and deletion safety.
- Performance review: **APPROVE — no findings**; selected for subprocess trees,
  bounded waits, and image loading.
- All first-pass findings were resolved and re-reviewed.
- Residual risks: local Docker/Kind/cgroup compatibility; trusted local
  Docker/Kubernetes access is required for marker authenticity; deletion
  intentionally destroys cluster-local PostgreSQL data; same-image reruns
  conservatively rebuild and load the image.
