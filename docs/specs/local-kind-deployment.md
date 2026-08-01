# Feature spec: Local Kind deployment

## Goal

Provide a self-contained local Kubernetes deployment for the Floor Control API
that an interviewer can run with Docker, Kind, and kubectl, without manually
configuring storage or a cloud service.

## Decisions

- Cluster target -> local Kind only (source: user)
- Database location -> PostgreSQL inside Kind (source: user)
- Database storage -> persistent volume claim bound to a static local hostPath PV (source: implementation)
- API replicas -> one (source: user; required by the current single-instance timeout worker)
- API exposure -> Kubernetes NodePort (source: user)
- Image workflow -> build locally and load into Kind with `kind load docker-image`; issue #20 uses mutable placeholder `floor-control-api:kind-local`, while issue #21 renders one immutable `kind-<git-sha>` tag for both workloads (source: user/implementation)
- Migration workflow -> dedicated migration Job before the API Deployment (source: user-approved recommendation)
- Deployment and cleanup scripts -> deferred to issue #21 (source: scope boundary)
- Rerun behavior -> reuse credentials/PVC, wait for any fixed-name migration Job, inspect the terminal Failed condition only after a wait failure, delete only completed/terminal-failed Jobs, recreate from the current image, then apply the API and wait for readiness (source: user-approved plan/implementation)

## Assumptions

- The interviewer has Docker, Kind, and kubectl installed.
- The deployment is development/demo-only and does not provide production-grade PostgreSQL backup, failover, or multi-instance coordination.
- The manifest uses a static hostPath PV; no storage-class setup is required for
  the one-node Kind cluster, and no cluster-name-specific node affinity is used.
- Secrets are generated or supplied locally and are not committed to the repository.
- The API remains at one replica until distributed timeout coordination is designed.
- Existing Secret and PVC data are reused on reruns; password rotation is a
  separate coordinated database operation.

## Out of scope

- Cloud Kubernetes providers or managed databases.
- Helm charts, unless implementation evidence shows they materially simplify the local workflow.
- Production-grade PostgreSQL backup, failover, TLS certificate provisioning, or ingress.
- Scaling the API beyond one replica.
- Changes to floor-control business behavior or the public API contract.

## Acceptance criteria

1. Issue #21 creates or reuses a named Kind cluster and loads the immutable local image.
2. The manifests provision persistent PostgreSQL storage without manual storage configuration.
3. PostgreSQL runs inside Kind and becomes ready before dependent resources proceed.
4. A migration Job applies pending Ecto migrations successfully before the API is considered ready.
5. A one-replica API Deployment starts with required Secrets and non-secret configuration.
6. A NodePort Service exposes the API on node port 30080.
7. API liveness `/` and database-aware readiness `/ready` probes are configured.
8. PostgreSQL data survives Pod recreation but is intentionally lost with cluster deletion.
9. Issue #21 owns rerun, cleanup, URL discovery, and clean-cluster execution.

## Impacted areas

- Kubernetes manifests for Namespace, Secret, ConfigMap, PostgreSQL StatefulSet/Service/PVC, migration Job, API Deployment/Service
- `deploy/kind/README.md` direct manifest lifecycle notes
- `docs/agent-runs/` deployment journal
- Container/deployment verification checks

## Open risks

- The static PV is intentionally for the one-node Kind workflow and is not a multi-node storage solution.
- The migration Job and existing image entrypoint both have migration capability; explicit Kubernetes commands prevent duplicate migration execution.
- NodePort allocation and localhost access behavior can vary by host OS and Docker networking; the script must print or discover the actual reachable address.
- Persistent data survives Pod recreation but is deleted with the Kind cluster by the cleanup script.

GATE: spec approved by user on 2026-08-01
