#!/usr/bin/env bash
set -Eeuo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/floor-control-kind-verify.XXXXXX")"
chmod 700 "$tmp_root"
marker=""
marker_created=0
cleanup_marker() {
  if (( marker_created )); then
    curl --fail --silent --show-error --max-time 5 -X DELETE "$base/groups/$marker/floor/acceptance-marker" >/dev/null 2>&1 || true
  fi
  if [[ -d "$tmp_root" ]]; then rm -rf -- "$tmp_root"; fi
}
trap cleanup_marker EXIT
host_port="${KIND_HOST_PORT:-4000}"
cluster="${KIND_CLUSTER:-floor-control}"
namespace="${KIND_NAMESPACE:-floor-control}"
image="floor-control-api:kind-$(git rev-parse HEAD)"
[[ "$#" -eq 0 ]] || { printf 'Usage: %s\n' "$(basename "$0")" >&2; exit 1; }
[[ "$cluster" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { printf 'ERROR: KIND_CLUSTER must be a DNS-compatible name\n' >&2; exit 1; }
[[ "$namespace" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { printf 'ERROR: KIND_NAMESPACE must be a DNS-compatible name\n' >&2; exit 1; }
[[ "$host_port" =~ ^[0-9]+$ && "$host_port" -ge 1 && "$host_port" -le 65535 ]] || { printf 'ERROR: KIND_HOST_PORT must be between 1 and 65535\n' >&2; exit 1; }

command -v curl >/dev/null 2>&1 || { printf 'ERROR: curl is required\n' >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { printf 'ERROR: kubectl is required\n' >&2; exit 1; }
command -v kind >/dev/null 2>&1 || { printf 'ERROR: kind is required\n' >&2; exit 1; }
kubeconfig="$tmp_root/kubeconfig"
kind get kubeconfig --name "$cluster" >"$kubeconfig"
chmod 600 "$kubeconfig"
kube() { kubectl --kubeconfig "$kubeconfig" --request-timeout=30s "$@"; }
kubewatch() { kubectl --kubeconfig "$kubeconfig" "$@"; }
base="http://127.0.0.1:$host_port"
secret_uid="$(kube -n "$namespace" get secret floor-control-secrets -o jsonpath='{.metadata.uid}')"
job_uid="$(kube -n "$namespace" get job floor-control-migrate -o jsonpath='{.metadata.uid}')"
marker="kind-acceptance-$$"

for path in / /ready /swagger /openapi.yaml; do
  curl --fail --silent --show-error --max-time 5 "$base$path" >/dev/null || { printf 'ERROR: endpoint failed: %s%s\n' "$base" "$path" >&2; exit 1; }
done
curl --fail --silent --show-error --max-time 5 -X POST "$base/groups/$marker/floor" \
  -H 'content-type: application/json' --data '{"userId":"acceptance-marker","priority":1}' >/dev/null || { printf 'ERROR: could not create persistence marker\n' >&2; exit 1; }
marker_created=1

KIND_CLUSTER="$cluster" KIND_NAMESPACE="$namespace" KIND_HOST_PORT="$host_port" scripts/create-and-deploy-in-kind.sh >/dev/null
[[ "$(kube -n "$namespace" get secret floor-control-secrets -o jsonpath='{.metadata.uid}')" == "$secret_uid" ]] || { printf 'ERROR: Secret UID changed on rerun\n' >&2; exit 1; }
new_job_uid="$(kube -n "$namespace" get job floor-control-migrate -o jsonpath='{.metadata.uid}')"
[[ "$new_job_uid" == "$job_uid" ]] || { printf 'ERROR: completed migration Job was unexpectedly recreated on same-image rerun\n' >&2; exit 1; }
[[ "$(kube -n "$namespace" get job floor-control-migrate -o jsonpath='{.status.succeeded}')" == 1 ]] || { printf 'ERROR: migration Job is not complete\n' >&2; exit 1; }
curl --fail --silent --show-error --max-time 5 "$base/groups/$marker/floor" | grep -q 'acceptance-marker' || { printf 'ERROR: marker did not survive deployment rerun\n' >&2; exit 1; }

[[ "$(kube -n "$namespace" get deployment floor-control-api -o jsonpath='{.spec.replicas}')" == 1 ]] || { printf 'ERROR: API replica count is not 1\n' >&2; exit 1; }
[[ "$(kube -n "$namespace" get deployment floor-control-api -o jsonpath='{.status.readyReplicas}')" == 1 ]] || { printf 'ERROR: API is not exactly 1 ready replica\n' >&2; exit 1; }
[[ "$(kube -n "$namespace" get deployment floor-control-api -o jsonpath='{.spec.template.spec.containers[0].image}')" == "$image" ]] || { printf 'ERROR: API image does not match %s\n' "$image" >&2; exit 1; }
[[ "$(kube -n "$namespace" get secret floor-control-secrets -o jsonpath='{.metadata.uid}')" != "" ]] || { printf 'ERROR: deployment Secret is absent\n' >&2; exit 1; }
kube -n "$namespace" delete pod "$(kube -n "$namespace" get pods -l app.kubernetes.io/name=floor-control-api -o jsonpath='{.items[0].metadata.name}')" --wait=false >/dev/null
kubewatch -n "$namespace" wait --for=condition=available deployment/floor-control-api --timeout=180s >/dev/null
curl --fail --silent --show-error --max-time 5 "$base/groups/$marker/floor" | grep -q 'acceptance-marker' || { printf 'ERROR: marker did not survive API replacement\n' >&2; exit 1; }
kube -n "$namespace" delete pod postgres-0 --wait=false >/dev/null
kubewatch -n "$namespace" wait --for=condition=ready pod/postgres-0 --timeout=180s >/dev/null
marker_restored=0
for attempt in {1..36}; do
  if curl --fail --silent --show-error --max-time 5 "$base/ready" >/dev/null 2>&1 &&
    curl --fail --silent --show-error --max-time 5 "$base/groups/$marker/floor" | grep -q 'acceptance-marker'; then
    marker_restored=1
    break
  fi
  sleep 5
done
(( marker_restored == 1 )) || { printf 'ERROR: persistence marker did not survive PostgreSQL Pod replacement\n' >&2; exit 1; }
printf 'Kind acceptance checks passed: endpoints, readiness, one API replica, immutable image, completed migration, Secret reuse, and PostgreSQL Pod persistence.\n'
