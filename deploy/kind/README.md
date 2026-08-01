# Local Kind manifests

These manifests target one disposable, one-node Kind cluster. They deliberately
do not contain a Secret. The direct lifecycle below creates credentials once,
reuses them on reruns, and never places credential values in command arguments,
shell history, or output. Issue #21 should automate the same policy.

The API image is the mutable local placeholder tag `floor-control-api:kind-local`.
It is not a registry digest. Issue #21 must render a temporary copy using one
immutable `kind-<git-sha>` tag, load that exact tag into Kind, and use the same
rendered tag for the migration Job and API Deployment.

## First-run credentials and foundation

Namespace creation must precede Secret creation. On a fresh cluster, generate
the Secret once with protected temporary files, then apply the foundation. On a
rerun, an existing Secret is reused and no new credentials are generated.

```sh
set -eu

kubectl get namespace floor-control >/dev/null 2>&1 || \
  kubectl create namespace floor-control >/dev/null

secret_dir="$(mktemp -d "${TMPDIR:-/tmp}/floor-control-secret.XXXXXX")"
chmod 700 "$secret_dir"
trap 'rm -rf "$secret_dir"' EXIT

if kubectl -n floor-control get secret floor-control-secrets >/dev/null 2>&1; then
  printf '%s\n' 'Reusing existing floor-control-secrets'
else
  openssl rand -hex 32 >"$secret_dir/POSTGRES_PASSWORD"
  openssl rand -hex 64 >"$secret_dir/SECRET_KEY_BASE"
  chmod 600 "$secret_dir"/*
  password="$(<"$secret_dir/POSTGRES_PASSWORD")"
  printf 'ecto://floor_control:%s@postgres:5432/floor_control\n' "$password" \
    >"$secret_dir/DATABASE_URL"
  chmod 600 "$secret_dir/DATABASE_URL"

  kubectl -n floor-control create secret generic floor-control-secrets \
    --from-file=POSTGRES_PASSWORD="$secret_dir/POSTGRES_PASSWORD" \
    --from-file=SECRET_KEY_BASE="$secret_dir/SECRET_KEY_BASE" \
    --from-file=DATABASE_URL="$secret_dir/DATABASE_URL" >/dev/null
fi

kubectl apply -k deploy/kind
kubectl -n floor-control wait --for=condition=ready pod/postgres-0 --timeout=180s
```

The temporary directory is mode `700`, files are mode `600`, and only file
paths—not credential values—are passed to `kubectl`. The trap removes the files
on exit. Do not rotate this Secret during a normal rerun: changing the password
requires a coordinated PostgreSQL `ALTER ROLE` operation, or intentional data
reset, and is outside the normal local deployment lifecycle.

## Migration and API lifecycle

The root kustomization is foundation-only and must never start the API or run
migrations. The migration Job explicitly invokes `FloorControl.Release.migrate/0`;
the API explicitly invokes `start`, bypassing the image entrypoint migration.

```sh
set -eu

if kubectl -n floor-control get job floor-control-migrate >/dev/null 2>&1; then
  if kubectl -n floor-control wait --for=condition=complete \
    job/floor-control-migrate --timeout=300s; then
    :
  else
    failed_status="$(kubectl -n floor-control get job floor-control-migrate \
      -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}')"
    if [ "$failed_status" = True ]; then
      printf '%s\n' 'Existing migration Job is terminal Failed; replacing it' >&2
    else
      printf '%s\n' \
        'Existing migration Job is active, unknown, or timed out; refusing to delete it' >&2
      exit 1
    fi
  fi

  # Always recreate the fixed-name Job so this release runs pending migrations.
  kubectl -n floor-control delete job floor-control-migrate \
    --ignore-not-found --wait=true
fi

kubectl apply -k deploy/kind/migration
kubectl -n floor-control wait --for=condition=complete \
  job/floor-control-migrate --timeout=300s

kubectl apply -k deploy/kind/application
kubectl -n floor-control rollout status deployment/floor-control-api --timeout=180s
```

Job pod templates are immutable. Every new deployment waits for an existing
active Job to complete successfully. After a wait failure, only a Job with a
terminal Failed condition is deleted; active, unknown, and timed-out Jobs are
left in place and stop the lifecycle. Completed and terminal-failed Jobs are
then recreated before applying the current migration kustomization. Ecto skips
migration versions already recorded in the database, so this safely runs
pending migrations on every deployment. Issue #21 must apply the same lifecycle
after rendering the immutable Git-SHA image tag.

## Access and persistence

The API Service remains a NodePort on `30080`, exposed on Kind node interfaces.
Issue #21 should map node port `30080` to host `127.0.0.1`. Until then, use a
loopback-only port-forward for direct manifest testing:

```sh
kubectl -n floor-control port-forward --address 127.0.0.1 \
  svc/floor-control-api 4000:4000
```

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
