# Local Kind manifests

These manifests target one disposable, one-node Kind cluster. They deliberately
do not contain a Secret. The supported lifecycle scripts create credentials
once, reuse them on reruns, and never place credential values in command
arguments, shell history, or output.

The manifests use the mutable local placeholder tag `floor-control-api:kind-local`
for direct inspection. The supported create script renders one immutable
`kind-<git-sha>` tag, loads that exact tag into Kind, and uses it for both the
migration Job and API Deployment.

## Automated lifecycle (issue #21)

From the repository root, the supported local lifecycle is:

```sh
scripts/create-and-deploy-in-kind.sh
scripts/verify-kind-deployment.sh
scripts/delete-kindly.sh
```

The create script requires Docker, Kind, kubectl, openssl, curl, git, and pgrep.
It builds and loads one immutable `floor-control-api:kind-<committed-sha>` image,
maps the NodePort to `127.0.0.1`, waits for PostgreSQL and migrations, and
prints loopback API/Swagger/OpenAPI URLs. `KIND_CLUSTER`, `KIND_NAMESPACE`,
`KIND_HOST_PORT`, `KIND_NODE_PORT`, and `KIND_NODE_IMAGE` are overridable.
The node-image override must remain digest-pinned (`name@sha256:<64 hex>`).
Unrelated untracked files and documentation changes are allowed. Any tracked or
untracked file under the image-build inputs (`Dockerfile`, `.dockerignore`,
`docker-entrypoint.sh`, `mix.exs`, `mix.lock`, `.formatter.exs`, `config/`,
`lib/`, `priv/`) or the YAML inputs under `deploy/kind/` (including its
`foundation/`, `migration/`, and `application/` manifests) makes the deployment
stop until that input is committed or removed. Documentation-only files under
`deploy/kind/` do not trigger this guard. Reruns retain the Secret, PVC, and
PostgreSQL data. Deletion is intentional and removes the named cluster and its
local data only after verifying the automation ownership marker in
`kube-system`; a same-name unowned cluster is refused.

The default API port is `4000`; if Compose is running, use a free alternate
port such as `KIND_HOST_PORT=4001`. The script preserves the user's kubeconfig
context by using a protected temporary kubeconfig. For later inspection, use
`kind get kubeconfig` redirected to a mode-600 file in a mode-700 temporary
directory and pass it explicitly via `kubectl --kubeconfig`; remove that
directory when finished. Do not use the ambient kubectl context.
Deletion uses its own protected temporary kubeconfig and removes its temporary
log directory on normal exit, timeout, or interruption.

Automation-created Secrets are labeled as managed Floor Control resources and
must contain all three required keys on reuse. An unlabeled or incomplete
pre-automation Secret is rejected rather than silently adopted. A custom
namespace is also rejected if the cluster-global `postgres-data` PV is already
claimed by another namespace.

## Credentials and foundation

Do not apply the foundation or create the Secret manually with an ambient
kubectl context. Use `scripts/create-and-deploy-in-kind.sh`: it creates the
namespace first, generates the Secret through protected temporary files, adds
the required ownership labels, fails closed on lookup or adoption errors, and
reuses only a complete managed Secret. Credential values are never printed.
This keeps Secret and foundation ordering aligned with the supported lifecycle;
changing the password requires a coordinated PostgreSQL operation.

## Migration and API lifecycle

Use `scripts/create-and-deploy-in-kind.sh` for the foundation, migration Job,
and API Deployment in the required order. It waits for PostgreSQL and
migrations, applies the API only after migration completion, and waits for API
readiness. Do not run the kustomizations manually; the script's protected
temporary kubeconfig and immutable image rendering are part of the supported
lifecycle.

Job pod templates are immutable. Every rerun waits for an existing active Job
to complete successfully. After a wait failure, only a terminal Failed Job is
replaced; active, unknown, and timed-out Jobs are left in place and stop the
lifecycle. A completed Job for the same immutable image is retained. Ecto skips
migrations already recorded in the database.

## Access and persistence

The API Service remains a NodePort on `30080`, mapped by the supported script
to host `127.0.0.1` (host port `4000` by default). Use the protected inspection
block in the root README for status, logs, and endpoint checks; it passes the
standalone kubeconfig explicitly on every kubectl invocation. The create script
also prints the reachable API, Swagger, and OpenAPI URLs.

The static hostPath PV needs no storage-class installation, preserves data
across PostgreSQL Pod recreation, and is deleted with the Kind node/cluster. It
intentionally has no node affinity, so manifests do not depend on the cluster
name; the workflow still targets one node.

The PostgreSQL StatefulSet uses a short-lived root init container with only
`CHOWN` and `FOWNER` capabilities. It checks the data-root ownership with
`stat` and recursively fixes ownership only when the root is not `999:999`.
The database container runs as UID `999`, uses a read-only root filesystem, and
has writable `emptyDir` mounts at `/tmp` and `/var/run/postgresql`.

`ERL_AFLAGS` is set through the shared ConfigMap as a local Kind resource bound:
`+S 2:2 +SDcpu 1 +SDio 1`. This keeps the tiny demo workload within a 2GiB
Docker VM; it is not a production scheduler recommendation.
