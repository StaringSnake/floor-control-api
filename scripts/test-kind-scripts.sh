#!/usr/bin/env bash
set -Eeuo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"
command -v ps >/dev/null 2>&1 || { printf 'ERROR: ps is required\n' >&2; exit 1; }
create="scripts/create-and-deploy-in-kind.sh"
delete="scripts/delete-kindly.sh"
verify="scripts/verify-kind-deployment.sh"
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/floor-control-kind-tests.XXXXXX")"
chmod 700 "$tmp_dir"
trap 'rm -rf -- "$tmp_dir"' EXIT
output="$tmp_dir/output"
sentinel="$tmp_dir/default-kubeconfig"
behavior_dir="$tmp_dir/behavior"
mkdir -m 700 "$behavior_dir"
printf 'apiVersion: v1\nkind: Config\ncurrent-context: sentinel\n' >"$sentinel"
sentinel_before="$(shasum -a 256 "$sentinel" | awk '{print $1}')"
KUBECONFIG="$sentinel" "$create" --help >/dev/null
[[ "$(shasum -a 256 "$sentinel" | awk '{print $1}')" == "$sentinel_before" ]]
verify_tmp="$tmp_dir/verify-tmp"
mkdir -m 700 "$verify_tmp"
verify_fixture="$behavior_dir/verify-bin"
mkdir -m 700 "$verify_fixture"
verify_lookup="$verify_fixture/kubectl-lookup"
cat >"$verify_fixture/kind" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  version*) printf 'kind v0.32.0 go1.26.3 darwin/amd64\n' ;;
  'get clusters') printf 'floor-control\n' ;;
  'get kubeconfig '* ) printf '%s\n' 'apiVersion: v1' 'kind: Config' 'clusters: []' 'contexts: []' 'users: []' ;;
  *) printf 'unexpected fake kind invocation: %s\n' "$*" >&2; exit 91 ;;
esac
EOF
cat >"$verify_fixture/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$KIND_VERIFY_LOOKUP_FILE"
case "$*" in
  *'get secret floor-control-secrets'*)
    printf 'fake kubectl: intentional Secret lookup failure\n' >&2
    exit 42
    ;;
  *)
    printf 'unexpected fake kubectl invocation: %s\n' "$*" >&2
    exit 91
    ;;
esac
EOF
chmod 700 "$verify_fixture/kind" "$verify_fixture/kubectl"
verify_output="$tmp_dir/verify-output"
if TMPDIR="$verify_tmp" PATH="$verify_fixture:/usr/bin:/bin" KIND_VERIFY_LOOKUP_FILE="$verify_lookup" "$verify" >"$verify_output" 2>&1; then
  printf 'ERROR: verify unexpectedly passed its intentional Secret lookup failure\n' >&2
  exit 1
fi
grep -q 'intentional Secret lookup failure' "$verify_output"
grep -q 'get secret floor-control-secrets' "$verify_lookup"
[[ -z "$(compgen -G "$verify_tmp/floor-control-kind-verify.*" || true)" ]]
[[ ! -e "$verify_tmp/kubeconfig" ]]
for executable in bash git mktemp chmod rm; do
  ln -s "$(command -v "$executable")" "$verify_fixture/$executable"
done
cat >"$verify_fixture/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 700 "$verify_fixture/curl"
verify_output_ps="$tmp_dir/verify-output-ps"
if TMPDIR="$verify_tmp" PATH="$verify_fixture" "$verify" >"$verify_output_ps" 2>&1; then
  printf 'ERROR: verify unexpectedly passed missing ps preflight\n' >&2
  exit 1
fi
grep -q 'ps is required' "$verify_output_ps"
rm -f "$verify_fixture/bash" "$verify_fixture/git" "$verify_fixture/mktemp" "$verify_fixture/chmod" "$verify_fixture/rm" "$verify_fixture/curl"

for executable in bash git mktemp chmod rm ps; do
  ln -s "$(command -v "$executable")" "$verify_fixture/$executable"
done
cat >"$verify_fixture/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 700 "$verify_fixture/curl"
verify_output_pgrep="$tmp_dir/verify-output-pgrep"
if TMPDIR="$verify_tmp" PATH="$verify_fixture" "$verify" >"$verify_output_pgrep" 2>&1; then
  printf 'ERROR: verify unexpectedly passed missing pgrep preflight\n' >&2
  exit 1
fi
grep -q 'pgrep is required' "$verify_output_pgrep"
rm -f "$verify_fixture/bash" "$verify_fixture/git" "$verify_fixture/mktemp" "$verify_fixture/chmod" "$verify_fixture/rm" "$verify_fixture/ps" "$verify_fixture/curl"

expect_failure() {
  if "$@" >"$output" 2>&1; then
    printf 'ERROR: expected failure: %s\n' "$*" >&2
    exit 1
  fi
}

bash -n "$create" "$delete" "$verify"
expect_failure env KIND_NODE_PORT=29999 "$create"
grep -q 'between 30000 and 32767' "$output"
expect_failure env KIND_HOST_PORT=0 "$create"
grep -q 'between 1 and 65535' "$output"
expect_failure env KIND_CLUSTER='bad_name' "$create"
grep -q 'DNS-compatible name' "$output"
expect_failure env KIND_CLUSTER='bad_name' "$delete"
grep -q 'DNS-compatible name' "$output"
expect_failure env KIND_NODE_IMAGE='kindest/node:v1.31.4' "$create"
grep -q 'digest-pinned image' "$output"

grep -q 'docker port' "$create"
grep -q 'KIND_CREATE_TIMEOUT_SECONDS' "$create"
grep -q "pvc_phase=.*status.phase" "$create"
grep -q 'PVC postgres-data did not become Bound within 300 seconds' "$create"
grep -q 'mapping_count' "$create"
grep -q 'git status --porcelain' "$create"
grep -q 'KUBECONFIG=' "$create"
grep -q "trap 'handle_signal' INT TERM" "$create"
grep -q "trap 'handle_signal' INT TERM" "$delete"
library="scripts/kind-lifecycle-functions.sh"
grep -q 'validate_cluster_ownership' "$create"
grep -q 'validate_cluster_ownership' "$delete"
grep -q 'marker-version' "$library"
grep -q 'managed-by=floor-control-kind' "$library"
grep -q 'label --local' "$library"
if grep -q -- '--label=' "$library"; then exit 1; fi
grep -q 'missing required key' "$library"
grep -q 'claimRef.namespace' "$library"
grep -q 'namespace: floor-control' "$create"
grep -q 'newTag: kind-${git_sha}' "$create"
grep -q 'condition=complete' "$library"
grep -q 'type=="Failed"' "$library"
grep -q 'active, unknown, or timed out' "$library"
grep -q 'delete job floor-control-migrate' "$library"
grep -q 'Existing migration Job already completed' "$library"
grep -q 'new_job_uid' "$verify"
grep -q 'marker="kind-acceptance-\$\$"' "$verify"
if grep -F -q '${$}' "$verify"; then exit 1; fi
grep -q 'kind delete cluster --name "$cluster"' "$delete"
grep -q 'KIND_DELETE_TIMEOUT_SECONDS' "$delete"
grep -q 'kind get kubeconfig' "$verify"
grep -q 'wait_for_api_marker' "$verify"
grep -q 'create_postgres_persistence_marker' "$verify"
grep -q 'cleanup_postgres_persistence_marker' "$verify"
grep -q 'postgres_kube()' "$library"
grep -q 'pgrep is required' "$verify"
grep -q 'request-timeout=5s' "$library"
grep -q 'run_with_timeout 190 kubewatch' "$verify"
grep -q -- '--timeout=180s' "$verify"
grep -q 'for attempt in {1..9}' "$verify"
! grep -q 'kubewatch() .*request-timeout' "$library"

(
  set -Eeuo pipefail
  source "$library"
  kubeconfig=test-kubeconfig
  kubectl() { printf '%s\n' "$*" >"$behavior_dir/kubectl-timeout-call"; }
  kubewatch wait --for=condition=ready pod/postgres-0 --timeout=180s
  grep -q -- '--kubeconfig test-kubeconfig wait --for=condition=ready pod/postgres-0 --timeout=180s' "$behavior_dir/kubectl-timeout-call"
  ! grep -q -- '--request-timeout' "$behavior_dir/kubectl-timeout-call"
  postgres_kube exec postgres-0 -- true
  grep -q -- '--request-timeout=5s exec postgres-0 -- true' "$behavior_dir/kubectl-timeout-call"
)

timeout_fixture="$behavior_dir/timeout-fixture"
timeout_child_pid="$behavior_dir/timeout-child.pid"
cat >"$timeout_fixture" <<EOF
#!/usr/bin/env bash
trap '' TERM
(trap '' TERM; sleep 30) &
printf '%s\n' "\$!" >"$timeout_child_pid"
wait
EOF
chmod 700 "$timeout_fixture"
if (
  set -Eeuo pipefail
  source "$library"
  run_with_timeout 1 "$timeout_fixture"
); then
  printf 'ERROR: TERM-ignoring timeout fixture unexpectedly passed\n' >&2
  exit 1
else
  [[ "$?" == 124 ]]
fi
timeout_child="$(<"$timeout_child_pid")"
if kill -0 "$timeout_child" 2>/dev/null; then
  printf 'ERROR: outer timeout left a descendant alive\n' >&2
  exit 1
fi

(
  set -Eeuo pipefail
  source "$library"
  kubeconfig=test-kubeconfig
  kubectl() { return 124; }
  if run_with_timeout 1 kubewatch wait --for=condition=ready pod/postgres-0 --timeout=180s; then
    exit 1
  else
    [[ "$?" == 124 ]]
  fi
)

(
  set -Eeuo pipefail
  source "$library"
  NAMESPACE=test
  postgres_marker_created=0
  postgres_calls="$behavior_dir/postgres-marker-calls"
  postgres_kube() {
    printf '%s\n' "$*" >>"$postgres_calls"
    case "$*" in
      *'SELECT marker FROM "kind_acceptance_123";'*) printf 'postgres-persistence-kind-acceptance-123\n' ;;
      *) : ;;
    esac
  }
  create_postgres_persistence_marker kind-acceptance-123
  check_postgres_persistence_marker
  cleanup_postgres_persistence_marker
  grep -q 'CREATE TABLE "kind_acceptance_123"' "$postgres_calls"
  grep -q 'BEGIN; CREATE TABLE' "$postgres_calls"
  grep -q 'COMMIT;' "$postgres_calls"
  grep -q 'statement_timeout=10000' "$postgres_calls"
  grep -q 'lock_timeout=5000' "$postgres_calls"
  grep -q 'DROP TABLE IF EXISTS "kind_acceptance_123"' "$postgres_calls"
  [[ -z "$postgres_marker_table" && -z "$postgres_marker_value" ]]
  [[ "$postgres_marker_created" == 0 ]]
)

if (
  set -Eeuo pipefail
  source "$library"
  NAMESPACE=test
  postgres_calls="$behavior_dir/postgres-collision-calls"
  postgres_kube() {
    printf '%s\n' "$*" >>"$postgres_calls"
    return 17
  }
  if create_postgres_persistence_marker kind-acceptance-456; then exit 1; fi
  postgres_marker_created=0
  cleanup_postgres_persistence_marker
  ! grep -q 'DROP TABLE' "$postgres_calls"
  [[ -z "$postgres_marker_table" && -z "$postgres_marker_value" ]]
); then
  printf 'ERROR: failed PostgreSQL marker creation attempted cleanup DROP\n' >&2
  exit 1
fi

if (
  set -Eeuo pipefail
  source "$library"
  NAMESPACE=test
  postgres_marker_table='kind_acceptance_123'
  postgres_marker_value='postgres-persistence-kind-acceptance-123'
  postgres_marker_created=1
  postgres_kube() { return 17; }
  cleanup_postgres_persistence_marker
  [[ -z "$postgres_marker_table" && -z "$postgres_marker_value" ]]
  [[ "$postgres_marker_created" == 0 ]]
); then
  :
else
  printf 'ERROR: PostgreSQL marker cleanup did not remain best-effort\n' >&2
  exit 1
fi

if create_postgres_persistence_marker 'kind-acceptance-bad;drop' 2>/dev/null; then
  printf 'ERROR: PostgreSQL marker accepted an unsafe identifier\n' >&2
  exit 1
fi

(
  set -Eeuo pipefail
  source "$library"
  marker_state="$behavior_dir/transient-marker-calls"
  printf '0\n' >"$marker_state"
  curl() {
    [[ "$#" -eq 6 && "$1" == '--fail' && "$2" == '--silent' && "$3" == '--show-error' && "$4" == '--max-time' && "$5" == 5 ]] || return 92
    local url="${!#}"
    case "$url" in
      *'/ready') return 0 ;;
      *'/groups/test-marker/floor')
        marker_calls="$(( $(<"$marker_state") + 1 ))"
        printf '%s\n' "$marker_calls" >"$marker_state"
        (( marker_calls >= 2 )) && printf 'acceptance-marker\n'
        (( marker_calls >= 2 ))
        ;;
      *) return 91 ;;
    esac
  }
  if curl --fail --silent --show-error --max-time 5 http://127.0.0.1/ready >/dev/null 2>&1 &&
    curl --fail --silent --show-error --max-time 5 http://127.0.0.1/groups/test-marker/floor | grep -q 'acceptance-marker'; then
    printf 'ERROR: immediate marker behavior unexpectedly passed\n' >&2
    exit 1
  fi
  wait_for_api_marker http://127.0.0.1 test-marker 3 0
  [[ "$(<"$marker_state")" == 2 ]]
)

if (
  set -Eeuo pipefail
  source "$library"
  marker_state="$behavior_dir/persistent-marker-calls"
  printf '0\n' >"$marker_state"
  curl() {
    [[ "$#" -eq 6 && "$1" == '--fail' && "$2" == '--silent' && "$3" == '--show-error' && "$4" == '--max-time' && "$5" == 5 ]] || return 92
    local url="${!#}"
    case "$url" in
      *'/ready') return 0 ;;
      *'/groups/test-marker/floor')
        marker_calls="$(( $(<"$marker_state") + 1 ))"
        printf '%s\n' "$marker_calls" >"$marker_state"
        return 1
        ;;
      *) return 91 ;;
    esac
  }
  if wait_for_api_marker http://127.0.0.1 test-marker 3 0; then
    exit 1
  fi
  [[ "$(<"$marker_state")" == 3 ]] || exit 1
  false
); then
  printf 'ERROR: persistent API marker failure unexpectedly passed\n' >&2
  exit 1
fi

run_migration_case() {
  case_name="$1"
  expected_status="$2"
  expected_deleted="$3"
  if (
    set -Eeuo pipefail
    source "$library"
    NAMESPACE=test
    image=floor-control-api:kind-current
    rendered_dir="$behavior_dir"
    deleted=0
    die() { printf 'DIE: %s\n' "$*" >&2; exit 42; }
    kube() {
      case "$*" in
        *"get job"*"template.spec.containers[0].image"*)
          [[ "$case_name" == old ]] && printf 'floor-control-api:kind-old\n' || printf 'floor-control-api:kind-current\n'
          ;;
        *"get job"*"conditions"*)
          [[ "$case_name" == failed ]] && printf 'True\n'
          ;;
        *"get job floor-control-migrate"*) return 0 ;;
        *"delete job"*) deleted=1 ;;
        *"apply -f"*) : ;;
      esac
    }
    kube_watch() {
      case "$*" in
        *"condition=complete"*) [[ "$case_name" == same || "$case_name" == old || "$deleted" == 1 ]] && return 0 || return 1 ;;
        *) return 0 ;;
      esac
    }
    manage_migration_job
    [[ "$deleted" == "$expected_deleted" ]]
  ) >/dev/null 2>&1; then
    actual_status=0
  else
    actual_status=$?
  fi
  [[ "$actual_status" == "$expected_status" ]] || { printf 'ERROR: migration case %s returned %s, expected %s\n' "$case_name" "$actual_status" "$expected_status" >&2; exit 1; }
}

run_migration_case same 0 0
run_migration_case old 0 1
run_migration_case failed 0 1
run_migration_case active 42 0
run_migration_case timeout 42 0

if (
  set -Eeuo pipefail
  source "$library"
  CLUSTER=floor-control
  die() { exit 42; }
  kube() { printf 'unowned\n'; }
  validate_cluster_ownership
); then exit 1; fi

(
  set -Eeuo pipefail
  source "$library"
  CLUSTER=floor-control
  kube() {
    case "$*" in
      *'managed-by'*) printf 'floor-control-kind\n' ;;
      *'cluster-name'*) printf 'floor-control\n' ;;
      *'marker-version'*) printf '1\n' ;;
    esac
  }
  validate_cluster_ownership
)

secret_fixture="$behavior_dir/secret-bin"
mkdir -m 700 "$secret_fixture"
secret_calls="$behavior_dir/secret-calls"
secret_applied="$behavior_dir/secret-applied"
cat >"$secret_fixture/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KIND_SECRET_CALLS"
case "$*" in
  *'get secret'*) exit 1 ;;
  *'create secret'*) printf '%s\n' 'apiVersion: v1' 'kind: Secret' 'metadata:' '  name: floor-control-secrets' ;;
  *'label --local'*) exit 42 ;;
  *'apply -f'*) input="$(cat)"; [[ -z "$input" ]] || : >"$KIND_SECRET_APPLIED" ;;
  *) exit 0 ;;
esac
EOF
chmod 700 "$secret_fixture/kubectl"
if (
  set -Eeuo pipefail
  source "$library"
  NAMESPACE=test
  tmp_root="$behavior_dir"
  die() { exit 42; }
  kube() { PATH="$secret_fixture:/usr/bin:/bin" KIND_SECRET_CALLS="$secret_calls" KIND_SECRET_APPLIED="$secret_applied" kubectl "$@"; }
  validate_or_create_secret
); then
  printf 'ERROR: Secret label failure unexpectedly passed\n' >&2
  exit 1
fi
[[ ! -e "$secret_applied" ]]

if (
  set -Eeuo pipefail
  source "$library"
  NAMESPACE=custom
  die() { exit 42; }
  kube() { printf 'other\npostgres-data\n'; }
  validate_postgres_volume_claim
); then exit 1; fi

if (
  set -Eeuo pipefail
  source "$library"
  NAMESPACE=custom
  tmp_root="$behavior_dir"
  die() { exit 42; }
  kube() {
    case "$*" in
      *"get secret"*"managed-by"*) printf '\n' ;;
      *) return 0 ;;
    esac
  }
  validate_or_create_secret
); then exit 1; fi

delete_fixture="$behavior_dir/bin"
mkdir -m 700 "$delete_fixture"
cat >"$delete_fixture/kind" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == get && "$2" == clusters ]]; then
  [[ "${KIND_TEST_CLUSTER_PRESENT:-1}" == 1 ]] && printf 'floor-control\n'
  exit 0
fi
if [[ "$1" == get && "$2" == kubeconfig ]]; then
  printf '%s\n' 'apiVersion: v1' 'kind: Config' 'clusters: []' 'contexts: []' 'users: []'
  exit 0
fi
if [[ "$1" == delete ]]; then
  (trap '' TERM; sleep 300) &
  child="$!"
  printf '%s\n' "$child" >"$KIND_TEST_CHILD_PID_FILE"
  trap '' TERM
  wait "$child"
fi
EOF
cat >"$delete_fixture/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'managed-by'*) [[ "${KIND_TEST_OWNED:-0}" == 1 ]] && printf 'floor-control-kind\n' || printf 'unowned\n' ;;
  *'cluster-name'*) [[ "${KIND_TEST_OWNED:-0}" == 1 ]] && printf 'floor-control\n' || printf 'other\n' ;;
  *'marker-version'*) [[ "${KIND_TEST_OWNED:-0}" == 1 ]] && printf '1\n' || printf '2\n' ;;
  *) printf 'unexpected fake kubectl invocation: %s\n' "$*" >&2; exit 91 ;;
esac
EOF
chmod 700 "$delete_fixture/kind"
chmod 700 "$delete_fixture/kubectl"
child_pid_file="$behavior_dir/child.pid"
delete_sentinel="$behavior_dir/delete-kubeconfig"
printf 'delete-sentinel\n' >"$delete_sentinel"
delete_sentinel_before="$(shasum -a 256 "$delete_sentinel" | awk '{print $1}')"
if PATH="$delete_fixture:/usr/bin:/bin" KIND_TEST_CLUSTER_PRESENT=0 KUBECONFIG="$delete_sentinel" scripts/delete-kindly.sh >/dev/null 2>&1; then
  :
else
  printf 'ERROR: absent-cluster deletion unexpectedly failed\n' >&2
  exit 1
fi
[[ "$(shasum -a 256 "$delete_sentinel" | awk '{print $1}')" == "$delete_sentinel_before" ]]
if PATH="$delete_fixture:/usr/bin:/bin" KIND_TEST_OWNED=0 KIND_TEST_CHILD_PID_FILE="$child_pid_file" KIND_DELETE_TIMEOUT_SECONDS=30 scripts/delete-kindly.sh >/dev/null 2>&1; then
  printf 'ERROR: unowned cluster deletion unexpectedly succeeded\n' >&2
  exit 1
fi
[[ ! -e "$child_pid_file" ]]
if PATH="$delete_fixture:/usr/bin:/bin" KIND_TEST_OWNED=1 KIND_TEST_CHILD_PID_FILE="$child_pid_file" KIND_DELETE_TIMEOUT_SECONDS=30 scripts/delete-kindly.sh >/dev/null 2>&1; then
  printf 'ERROR: bounded delete fake unexpectedly succeeded\n' >&2
  exit 1
fi
child_pid="$(<"$child_pid_file")"
if kill -0 "$child_pid" 2>/dev/null; then
  printf 'ERROR: bounded delete left a TERM-ignoring descendant alive\n' >&2
  exit 1
fi

signal_child_pid_file="$behavior_dir/signal-child.pid"
PATH="$delete_fixture:/usr/bin:/bin" KIND_TEST_OWNED=1 KIND_TEST_CHILD_PID_FILE="$signal_child_pid_file" KIND_DELETE_TIMEOUT_SECONDS=30 scripts/delete-kindly.sh >/dev/null 2>&1 &
delete_pid="$!"
for _ in {1..50}; do
  [[ -e "$signal_child_pid_file" ]] && break
  sleep 0.1
done
kill -TERM "$delete_pid"
wait "$delete_pid" 2>/dev/null || true
signal_child_pid="$(<"$signal_child_pid_file")"
if kill -0 "$signal_child_pid" 2>/dev/null; then
  printf 'ERROR: interrupted delete left a TERM-ignoring descendant alive\n' >&2
  exit 1
fi

printf 'Deterministic Kind script static/preflight checks passed.\n'
