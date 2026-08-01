# 0001: Use a static hostPath PV for local Kind PostgreSQL

Status: Accepted
Date: 2026-08-01
Author: operations implementer

## Context
The local Kind deployment needs PostgreSQL persistence without requiring a
pre-existing storage class or a registry/cloud service. The cluster has one
node, and the database data must survive PostgreSQL Pod recreation while
remaining disposable with the Kind cluster. The cluster name is configurable.

## Decision
We will use a statically declared `hostPath` PersistentVolume and an explicitly
bound PVC for PostgreSQL. The one-node Kind workflow supplies the scheduling
constraint; the manifest has no cluster-name-specific node affinity and retains
the PV until the local cluster is deleted.

## Alternatives considered
- Pinned local-path provisioner: rejected because it adds another controller and a
  remote image/manifests provenance requirement for this small one-node workflow.
- Ephemeral `emptyDir`: rejected because it loses the database on Pod recreation.

## Consequences
The deployment is self-contained and has no manual storage setup, and Pod
recreation preserves the data inside the Kind node. It remains intentionally
limited to one node and cluster deletion loses the local database; production
backup, failover, and storage management remain out of scope.
