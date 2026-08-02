#!/usr/bin/env bash
# Build, load, and deploy the current committed application to local Kind.
set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
readonly CLUSTER="${KIND_CLUSTER:-floor-control}"
readonly NAMESPACE="${KIND_NAMESPACE:-floor-control}"
readonly HOST_PORT="${KIND_HOST_PORT:-4000}"
readonly NODE_PORT="${KIND_NODE_PORT:-30080}"
readonly NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.31.4@sha256:2cb39f7295fe7eafee0842b1052a599a4fb0f8bcf3f83d96c7f4864c357c6c30}"
readonly PLACEHOLDER="floor-control-api:kind-local"
readonly REQUIRED_MEMORY_BYTES=4000000000
readonly CREATE_TIMEOUT_SECONDS="${KIND_CREATE_TIMEOUT_SECONDS:-300}"

tmp_root=""
active_pid=""

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME

Builds the committed HEAD, loads floor-control-api:kind-<git-sha> into the
named local Kind cluster, and runs migrations before the one-replica API.

Environment overrides: KIND_CLUSTER (default: floor-control),
KIND_NAMESPACE (floor-control), KIND_HOST_PORT (4000), KIND_NODE_PORT (30080),
KIND_NODE_IMAGE (pinned v1.31.4 by default), and KIND_CREATE_TIMEOUT_SECONDS
(300, allowed range 60..900).

Reruns reuse the cluster, Secret, PVC, and PostgreSQL data. Use
scripts/delete-kindly.sh when intentionally deleting local data.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}
cleanup() {
  if [[ -n "$active_pid" ]] && kill -0 "$active_pid" 2>/dev/null; then
    terminate_process_tree "$active_pid"
    wait "$active_pid" 2>/dev/null || true
  fi
  if [[ -n "$tmp_root" && -d "$tmp_root" ]]; then
    rm -rf -- "$tmp_root"
  fi
}
handle_signal() {
  cleanup
  exit 130
}
trap cleanup EXIT
trap 'handle_signal' INT TERM

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
[[ "$#" -eq 0 ]] || die "unknown argument: $1 (use --help)"

current_root="$(pwd -P)"
repo_root="$(cd "$ROOT" 2>/dev/null && pwd -P || true)"
[[ -n "$ROOT" && "$current_root" == "$repo_root" ]] || die "run this script from the repository root: ${ROOT:-repository not found}"
source "$ROOT/scripts/kind-lifecycle-functions.sh"
[[ "$CLUSTER" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "KIND_CLUSTER must be a DNS-compatible name"
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || die "KIND_NAMESPACE must be a DNS-compatible name"
[[ "$HOST_PORT" =~ ^[0-9]+$ && "$HOST_PORT" -ge 1 && "$HOST_PORT" -le 65535 ]] || die "KIND_HOST_PORT must be between 1 and 65535"
[[ "$NODE_PORT" =~ ^[0-9]+$ && "$NODE_PORT" -ge 30000 && "$NODE_PORT" -le 32767 ]] || die "KIND_NODE_PORT must be between 30000 and 32767"
[[ "$NODE_IMAGE" != *$'\n'* && "$NODE_IMAGE" != *$'\r'* ]] || die "KIND_NODE_IMAGE must not contain newlines"
[[ "$NODE_IMAGE" =~ ^[^[:space:]@]+@sha256:[0-9a-fA-F]{64}$ ]] || die "KIND_NODE_IMAGE must be a digest-pinned image (name@sha256:<64 hex characters>)"
[[ "$CREATE_TIMEOUT_SECONDS" =~ ^[0-9]+$ && "$CREATE_TIMEOUT_SECONDS" -ge 60 && "$CREATE_TIMEOUT_SECONDS" -le 900 ]] || die "KIND_CREATE_TIMEOUT_SECONDS must be between 60 and 900"

for executable in docker kind kubectl openssl curl git pgrep; do
  command -v "$executable" >/dev/null 2>&1 || die "required executable not found: $executable"
done

docker_info="$(docker info --format '{{.MemTotal}}' 2>/dev/null)" || die "Docker daemon is unavailable; start Docker Desktop and retry"
[[ "$docker_info" =~ ^[0-9]+$ ]] || die "could not determine Docker memory; configure at least 4GB"
if (( docker_info < REQUIRED_MEMORY_BYTES )); then
  die "Docker reports less than 4GB (${docker_info} bytes); configure at least 4GB and retry"
fi

readonly BUILD_PATHS=(Dockerfile .dockerignore docker-entrypoint.sh mix.exs mix.lock .formatter.exs config lib priv)
readonly MANIFEST_PATHS=(deploy/kind/*.yaml deploy/kind/foundation/*.yaml deploy/kind/migration/*.yaml deploy/kind/application/*.yaml)
dirty_paths=("${BUILD_PATHS[@]}" "${MANIFEST_PATHS[@]}")
[[ -z "$(git status --porcelain -- "${dirty_paths[@]}")" ]] || die "image or Kind-manifest inputs are dirty; commit or remove changes before deploying"
git_sha="$(git rev-parse HEAD)" || die "cannot determine committed HEAD"
image="floor-control-api:kind-${git_sha}"

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/floor-control-kind.XXXXXX")"
chmod 700 "$tmp_root"
kubeconfig="$tmp_root/kubeconfig"
kind_local() { KUBECONFIG="$kubeconfig" kind "$@"; }
kind_local get kubeconfig --name "$CLUSTER" >"$kubeconfig" 2>/dev/null || true
chmod 600 "$kubeconfig"

cluster_exists=0
if kind_local get clusters 2>/dev/null | awk -v target="$CLUSTER" '$1 == target { found = 1 } END { exit(found ? 0 : 1) }'; then
  cluster_exists=1
fi

port_in_use() {
  if docker ps --format '{{.Names}}\t{{.Ports}}' | awk -v port=":$HOST_PORT->" '$0 ~ port { found = 1 } END { exit(found ? 0 : 1) }'; then
    return 0
  fi
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$HOST_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

if (( cluster_exists == 0 )) && port_in_use; then
  die "127.0.0.1:$HOST_PORT is already in use; choose KIND_HOST_PORT=<free port> (the current Compose API uses 4000)"
fi

if (( cluster_exists == 0 )); then
  cluster_config="$tmp_root/kind-config.yaml"
  cat >"$cluster_config" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $CLUSTER
nodes:
  - role: control-plane
    image: $NODE_IMAGE
    extraPortMappings:
      - containerPort: $NODE_PORT
        hostPort: $HOST_PORT
        listenAddress: 127.0.0.1
        protocol: TCP
EOF
  chmod 600 "$cluster_config"
  printf 'Creating Kind cluster %s with loopback port 127.0.0.1:%s...\n' "$CLUSTER" "$HOST_PORT"
  kind_create_log="$tmp_root/kind-create.log"
  KUBECONFIG="$kubeconfig" kind create cluster --name "$CLUSTER" --config "$cluster_config" --wait "${CREATE_TIMEOUT_SECONDS}s" >"$kind_create_log" 2>&1 &
  kind_pid=$!
  active_pid="$kind_pid"
  for ((attempt = 1; attempt <= CREATE_TIMEOUT_SECONDS; attempt++)); do
    if ! kill -0 "$kind_pid" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  if kill -0 "$kind_pid" 2>/dev/null; then
    terminate_process_tree "$kind_pid"
    wait "$kind_pid" 2>/dev/null || true
    active_pid=""
    cat "$kind_create_log" >&2
    die "Kind cluster creation timed out after ${CREATE_TIMEOUT_SECONDS} seconds; inspect or delete only the disposable $CLUSTER cluster"
  fi
  if ! wait "$kind_pid"; then
    active_pid=""
    cat "$kind_create_log" >&2
    die "Kind cluster creation failed; inspect or delete only the disposable $CLUSTER cluster"
  fi
  active_pid=""
  cat "$kind_create_log"
else
  printf 'Reusing existing Kind cluster %s; validating its topology...\n' "$CLUSTER"
fi

kind_local get kubeconfig --name "$CLUSTER" >"$kubeconfig"
chmod 600 "$kubeconfig"
context="kind-$CLUSTER"
kube() { kubectl --kubeconfig "$kubeconfig" --request-timeout=30s "$@"; }
kube_watch() { kubectl --kubeconfig "$kubeconfig" "$@"; }
if (( cluster_exists )); then
  validate_cluster_ownership
else
  create_cluster_ownership_marker
fi

node_names="$(kind_local get nodes --name "$CLUSTER")"
node_count="$(printf '%s\n' "$node_names" | awk 'NF { count++ } END { print count + 0 }')"
[[ "$node_count" == 1 ]] || die "expected exactly one Kind node/control-plane; found $node_count"
node_name="$(printf '%s\n' "$node_names" | awk 'NF { print; exit}')"
node_role="$(docker inspect --format '{{index .Config.Labels "io.x-k8s.kind.role"}}' "$node_name" 2>/dev/null || true)"
[[ "$node_role" == control-plane ]] || die "Kind node $node_name is not the expected control-plane"
actual_node_image="$(docker inspect --format '{{.Config.Image}}' "$node_name" 2>/dev/null || true)"
requested_node_image="${NODE_IMAGE#docker.io/}"
actual_node_image="${actual_node_image#docker.io/}"
[[ "$actual_node_image" == "$requested_node_image" ]] || die "node image is '$actual_node_image', expected pinned '$requested_node_image'; refusing to recreate or delete data"

mapping="$(docker port "$node_name" "$NODE_PORT/tcp" 2>/dev/null || true)"
mapping_count="$(printf '%s\n' "$mapping" | awk 'NF { count++ } END { print count + 0 }')"
[[ "$mapping_count" == 1 ]] || die "expected exactly one port mapping for $NODE_PORT/tcp, found $mapping_count"
expected_mapping="127.0.0.1:$HOST_PORT"
actual_mapping="$(printf '%s\n' "$mapping" | awk '{print $NF}')"
[[ "$actual_mapping" == "$expected_mapping" ]] || die "cluster port mapping is '$actual_mapping', expected '$expected_mapping'; refusing to recreate or delete data"
kube_watch wait --for=condition=Ready node --all --timeout=120s >/dev/null || die "Kind node is not Ready; inspect after exporting kubeconfig with: kind export kubeconfig --name $CLUSTER"

validate_postgres_volume_claim

printf 'Building immutable local image %s...\n' "$image"
docker build --tag "$image" .
kind_local load docker-image "$image" --name "$CLUSTER"
loaded="$(docker exec "$node_name" crictl images -q "$image" 2>/dev/null || true)"
[[ -n "$loaded" ]] || die "Kind node containerd does not contain $image"

rendered_dir="$tmp_root/rendered"
mkdir -m 700 "$rendered_dir" "$rendered_dir/migration" "$rendered_dir/application"
for workload in migration application; do
  source_dir="$ROOT/deploy/kind/$workload"
  work_dir="$rendered_dir/$workload"
  cp "$source_dir/kustomization.yaml" "$work_dir/kustomization.yaml"
  sed "s/newTag: kind-local/newTag: kind-${git_sha}/" "$work_dir/kustomization.yaml" >"$work_dir/kustomization.yaml.tmp"
  chmod 600 "$work_dir/kustomization.yaml.tmp"
  mv "$work_dir/kustomization.yaml.tmp" "$work_dir/kustomization.yaml"
  for manifest in "$source_dir"/*.yaml; do
    [[ "$(basename "$manifest")" == kustomization.yaml ]] && continue
    target="$work_dir/$(basename "$manifest")"
    sed "s/namespace: floor-control/namespace: $NAMESPACE/g" "$manifest" >"$target"
    chmod 600 "$target"
  done
  resource_count="$(grep -R -o "$PLACEHOLDER" "$work_dir"/*.yaml | wc -l | tr -d ' ')"
  [[ "$resource_count" == 1 ]] || die "expected exactly one image placeholder in $workload resources, found $resource_count"
  resource="$work_dir/api-migration-job.yaml"
  [[ "$workload" == application ]] && resource="$work_dir/api-deployment.yaml"
  sed "s#${PLACEHOLDER}#${image}#g" "$resource" >"$resource.tmp"
  chmod 600 "$resource.tmp"
  mv "$resource.tmp" "$resource"
  rendered="$rendered_dir/$workload.yaml"
  kube kustomize "$work_dir" >"$rendered"
  chmod 600 "$rendered"
  ! grep -q "$PLACEHOLDER" "$work_dir"/*.yaml "$rendered" || die "placeholder remains in rendered $workload manifests"
  grep -q "newTag: kind-${git_sha}" "$work_dir/kustomization.yaml" || die "immutable image tag is absent from $workload kustomization"
  grep -q "$image" "$rendered" || die "immutable image is absent from rendered $workload manifest"
  if [[ "$NAMESPACE" != floor-control ]]; then
    ! grep -q 'namespace: floor-control' "$work_dir"/*.yaml || die "default namespace remains in rendered $workload resources"
  fi
done

foundation_dir="$tmp_root/foundation"
cp -R "$ROOT/deploy/kind/foundation" "$foundation_dir"
for manifest in "$foundation_dir"/*.yaml; do
  sed "s/namespace: floor-control/namespace: $NAMESPACE/g" "$manifest" >"$manifest.tmp"
  chmod 600 "$manifest.tmp"
  mv "$manifest.tmp" "$manifest"
done
sed "s/name: floor-control$/name: $NAMESPACE/" "$foundation_dir/namespace.yaml" >"$foundation_dir/namespace.yaml.tmp"
chmod 600 "$foundation_dir/namespace.yaml.tmp"
mv "$foundation_dir/namespace.yaml.tmp" "$foundation_dir/namespace.yaml"

kube apply -f "$foundation_dir/namespace.yaml" >/dev/null
validate_or_create_secret

kube apply -k "$foundation_dir" >/dev/null
for ((attempt = 1; attempt <= 300; attempt++)); do
  pvc_phase="$(kube -n "$NAMESPACE" get pvc/postgres-data -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$pvc_phase" == Bound ]]; then
    break
  fi
  if (( attempt == 300 )); then
    die "PVC postgres-data did not become Bound within 300 seconds"
  fi
  sleep 1
done
kube_watch -n "$NAMESPACE" wait --for=condition=ready pod/postgres-0 --timeout=300s >/dev/null

manage_migration_job

current_image="$(kube -n "$NAMESPACE" get deployment floor-control-api -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [[ "$current_image" == "$image" ]]; then
  printf 'API already uses %s; Kubernetes will retain the existing Pod template\n' "$image"
fi
kube -n "$NAMESPACE" apply -f "$rendered_dir/application.yaml" >/dev/null
kube_watch -n "$NAMESPACE" rollout status deployment/floor-control-api --timeout=180s >/dev/null

api_url="http://127.0.0.1:$HOST_PORT"
for attempt in {1..36}; do
  if curl --fail --silent --show-error --max-time 5 "$api_url/ready" >/dev/null 2>&1; then
    break
  fi
  if (( attempt == 36 )); then die "API readiness check failed at $api_url/ready"; fi
  sleep 5
done

printf '\nDeployment ready (image: %s)\n' "$image"
printf 'API:      %s/\n' "$api_url"
printf 'Ready:    %s/ready\n' "$api_url"
printf 'Swagger:  %s/swagger\n' "$api_url"
printf 'OpenAPI:  %s/openapi.yaml\n' "$api_url"
printf 'Status:   kind export kubeconfig --name %s && kubectl --context kind-%s -n %s get pods,job,pvc\n' "$CLUSTER" "$CLUSTER" "$NAMESPACE"
printf 'Logs:     kind export kubeconfig --name %s && kubectl --context kind-%s -n %s logs deployment/floor-control-api\n' "$CLUSTER" "$CLUSTER" "$NAMESPACE"
