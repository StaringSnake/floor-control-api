#!/usr/bin/env bash
set -Eeuo pipefail

cluster="${KIND_CLUSTER:-floor-control}"
CLUSTER="$cluster"
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
source "$script_dir/kind-lifecycle-functions.sh"
readonly DELETE_TIMEOUT_SECONDS="${KIND_DELETE_TIMEOUT_SECONDS:-120}"
tmp_root=""
active_pid=""

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
[[ "$cluster" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { printf 'ERROR: KIND_CLUSTER must be a DNS-compatible name\n' >&2; exit 1; }
[[ "$DELETE_TIMEOUT_SECONDS" =~ ^[0-9]+$ && "$DELETE_TIMEOUT_SECONDS" -ge 30 && "$DELETE_TIMEOUT_SECONDS" -le 600 ]] || { printf 'ERROR: KIND_DELETE_TIMEOUT_SECONDS must be between 30 and 600\n' >&2; exit 1; }
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  printf 'Usage: KIND_CLUSTER=<name> %s\n\nDeletes only the named local Kind cluster and its PostgreSQL data.\n' "$(basename "$0")"
  exit 0
fi
[[ "$#" -eq 0 ]] || { printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 1; }
command -v kind >/dev/null 2>&1 || { printf 'ERROR: required executable not found: kind\n' >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { printf 'ERROR: required executable not found: kubectl\n' >&2; exit 1; }
command -v pgrep >/dev/null 2>&1 || { printf 'ERROR: required executable not found: pgrep\n' >&2; exit 1; }

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/floor-control-kind-delete.XXXXXX")"
chmod 700 "$tmp_root"
kubeconfig="$tmp_root/kubeconfig"
kind_local() { KUBECONFIG="$kubeconfig" kind "$@"; }
kube() { kubectl --kubeconfig "$kubeconfig" --request-timeout=30s "$@"; }

if kind_local get clusters 2>/dev/null | awk -v target="$cluster" '$1 == target { found = 1 } END { exit(found ? 0 : 1) }'; then
  kind_local get kubeconfig --name "$cluster" >"$kubeconfig"
  chmod 600 "$kubeconfig"
  validate_cluster_ownership
  printf 'Deleting Kind cluster %s and its local PostgreSQL data.\n' "$cluster"
  kind_delete_log="$tmp_root/delete.log"
  : >"$kind_delete_log"
  chmod 600 "$kind_delete_log"
  KUBECONFIG="$kubeconfig" kind delete cluster --name "$cluster" >"$kind_delete_log" 2>&1 &
  kind_pid=$!
  active_pid="$kind_pid"
  for ((attempt = 1; attempt <= DELETE_TIMEOUT_SECONDS; attempt++)); do
    if ! kill -0 "$kind_pid" 2>/dev/null; then break; fi
    sleep 1
  done
  if kill -0 "$kind_pid" 2>/dev/null; then
    terminate_process_tree "$kind_pid"
    wait "$kind_pid" 2>/dev/null || true
    active_pid=""
    cat "$kind_delete_log" >&2
    printf 'ERROR: deletion timed out after %s seconds; inspect only cluster %s\n' "$DELETE_TIMEOUT_SECONDS" "$cluster" >&2
    exit 1
  fi
  if ! wait "$kind_pid"; then
    active_pid=""
    cat "$kind_delete_log" >&2
    exit 1
  fi
  active_pid=""
  cat "$kind_delete_log"
else
  printf 'Kind cluster %s is already absent; no other cluster or resource was changed.\n' "$cluster"
fi
