#!/usr/bin/env bash

kubewatch() { kubectl --kubeconfig "$kubeconfig" "$@"; }
postgres_kube() { kubectl --kubeconfig "$kubeconfig" --request-timeout=5s "$@"; }

terminate_process_tree() {
  local root_pid="$1" pid children
  local -a tree_pids=()

  collect_process_tree() {
    local parent="$1" child
    for child in $(pgrep -P "$parent" 2>/dev/null || true); do
      collect_process_tree "$child"
    done
    tree_pids+=("$parent")
  }

  collect_process_tree "$root_pid"
  for pid in "${tree_pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in {1..20}; do
    local alive=0
    for pid in "${tree_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; break; fi
    done
    (( alive == 0 )) && break
    sleep 0.1
  done
  for pid in "${tree_pids[@]}"; do kill -KILL "$pid" 2>/dev/null || true; done
  for _ in {1..20}; do
    local alive=0
    for pid in "${tree_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; break; fi
    done
    (( alive == 0 )) && break
    sleep 0.1
  done
  wait "$root_pid" 2>/dev/null || true
}

run_with_timeout() {
  local timeout_seconds="$1" pid ticks status process_state
  shift
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 2

  "$@" &
  pid="$!"
  for ((ticks = 0; ticks < timeout_seconds * 10; ticks++)); do
    process_state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
    if ! kill -0 "$pid" 2>/dev/null || [[ "$process_state" == Z* ]]; then
      if wait "$pid"; then
        return 0
      else
        status="$?"
        return "$status"
      fi
    fi
    sleep 0.1
  done

  terminate_process_tree "$pid"
  return 124
}

wait_for_api_marker() {
  local base_url="$1" marker="$2" attempts="$3" delay_seconds="$4" attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl --fail --silent --show-error --max-time 5 "$base_url/ready" >/dev/null 2>&1 &&
      curl --fail --silent --show-error --max-time 5 "$base_url/groups/$marker/floor" | grep -q 'acceptance-marker'; then
      return 0
    fi
    (( attempt == attempts )) || sleep "$delay_seconds"
  done
  return 1
}

create_postgres_persistence_marker() {
  local marker="$1" table_name sql sql_marker
  [[ "$marker" =~ ^kind-acceptance-[0-9]+$ ]] || return 2
  table_name="kind_acceptance_${marker#kind-acceptance-}"
  local marker_value="postgres-persistence-$marker"
  sql_marker="${marker_value//\'/\'\'}"
  sql="BEGIN; CREATE TABLE \"$table_name\" (marker text NOT NULL); INSERT INTO \"$table_name\" (marker) VALUES ('$sql_marker'); COMMIT;"
  run_with_timeout 15 postgres_exec_sql "$sql" >/dev/null
  postgres_marker_table="$table_name"
  postgres_marker_value="$marker_value"
  postgres_marker_created=1
}

check_postgres_persistence_marker() {
  local output
  [[ -n "${postgres_marker_table:-}" && -n "${postgres_marker_value:-}" ]] || return 2
  output="$(run_with_timeout 15 postgres_exec_sql "SELECT marker FROM \"$postgres_marker_table\";")"
  [[ "$output" == "$postgres_marker_value" ]]
}

cleanup_postgres_persistence_marker() {
  if [[ "${postgres_marker_created:-0}" == 1 && -n "${postgres_marker_table:-}" ]]; then
    run_with_timeout 15 postgres_exec_sql "DROP TABLE IF EXISTS \"$postgres_marker_table\";" \
      >/dev/null 2>&1 || true
  fi
  postgres_marker_table=""
  postgres_marker_value=""
  postgres_marker_created=0
}

postgres_exec_sql() {
  local sql="$1"
  postgres_kube -n "$NAMESPACE" exec postgres-0 -c postgres -- \
    sh -ec 'PGCONNECT_TIMEOUT=5 PGOPTIONS="-c statement_timeout=10000 -c lock_timeout=5000" PGPASSWORD="$POSTGRES_PASSWORD" psql --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" --tuples-only --no-align --set=ON_ERROR_STOP=1 --command="$1"' \
    -- "$sql"
}

validate_cluster_ownership() {
  local marker_name="floor-control-kind-ownership" managed_by cluster_name marker_version
  managed_by="$(kube -n kube-system get configmap "$marker_name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  cluster_name="$(kube -n kube-system get configmap "$marker_name" -o jsonpath='{.data.cluster-name}' 2>/dev/null || true)"
  marker_version="$(kube -n kube-system get configmap "$marker_name" -o jsonpath='{.data.marker-version}' 2>/dev/null || true)"
  [[ "$managed_by" == floor-control-kind && "$cluster_name" == "$CLUSTER" && "$marker_version" == 1 ]] ||
    die "Kind cluster $CLUSTER is not owned by floor-control-kind; refusing to adopt or mutate it"
}

create_cluster_ownership_marker() {
  local marker_file="$tmp_root/ownership-marker.yaml"
  cat >"$marker_file" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: floor-control-kind-ownership
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: floor-control-kind
data:
  cluster-name: "$CLUSTER"
  marker-version: "1"
EOF
  chmod 600 "$marker_file"
  kube apply -f "$marker_file" >/dev/null
}

delete_migration_job() {
  if ! kube -n "$NAMESPACE" delete job floor-control-migrate --wait=true --timeout=30s --request-timeout=30s >/dev/null; then
    die "could not delete migration Job within 30 seconds; inspect it before retrying"
  fi
}

manage_migration_job() {
  run_migration=1
  if kube -n "$NAMESPACE" get job floor-control-migrate >/dev/null 2>&1; then
    if kube_watch -n "$NAMESPACE" wait --for=condition=complete job/floor-control-migrate --timeout=300s >/dev/null 2>&1; then
      existing_job_image="$(kube -n "$NAMESPACE" get job floor-control-migrate -o jsonpath='{.spec.template.spec.containers[0].image}')"
      if [[ "$existing_job_image" == "$image" ]]; then
        printf 'Existing migration Job already completed for %s; retaining it\n' "$image"
        run_migration=0
      else
        printf '%s\n' 'Existing migration Job completed for an older image; replacing it'
        delete_migration_job
      fi
    else
      failed="$(kube -n "$NAMESPACE" get job floor-control-migrate -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || true)"
      if [[ "$failed" == "True" ]]; then
        printf '%s\n' 'Existing migration Job failed; replacing it' >&2
        delete_migration_job
      else
        die "migration Job is active, unknown, or timed out; refusing to delete it"
      fi
    fi
  fi

  if (( run_migration )); then
    printf '%s\n' 'Applying migration Job and waiting for completion...'
    kube -n "$NAMESPACE" apply -f "$rendered_dir/migration.yaml" >/dev/null
    if ! kube_watch -n "$NAMESPACE" wait --for=condition=complete job/floor-control-migrate --timeout=300s >/dev/null 2>&1; then
      printf '%s\n' 'Migration Job did not complete. Recent safe application logs:' >&2
      kube -n "$NAMESPACE" logs job/floor-control-migrate --all-containers=true --tail=100 >&2 || true
      die "migration failed; API was not deployed"
    fi
  fi
}

validate_postgres_volume_claim() {
  local claim_namespace claim_name
  claim_namespace="$(kube get pv postgres-data -o jsonpath='{.spec.claimRef.namespace}' 2>/dev/null || true)"
  claim_name="$(kube get pv postgres-data -o jsonpath='{.spec.claimRef.name}' 2>/dev/null || true)"
  if [[ -n "$claim_namespace" && ( "$claim_namespace" != "$NAMESPACE" || "$claim_name" != postgres-data ) ]]; then
    die "PersistentVolume postgres-data is reserved by ${claim_namespace}/${claim_name}; refusing namespace override and data mutation"
  fi
}

validate_or_create_secret() {
  local secret_name="floor-control-secrets" managed_by part_of key secret_value secret_dir password
  if kube -n "$NAMESPACE" get secret "$secret_name" >/dev/null 2>&1; then
    managed_by="$(kube -n "$NAMESPACE" get secret "$secret_name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
    part_of="$(kube -n "$NAMESPACE" get secret "$secret_name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null || true)"
    [[ "$managed_by" == floor-control-kind && "$part_of" == floor-control ]] || die "Secret $NAMESPACE/$secret_name exists but is not managed by floor-control-kind; refusing to adopt it"
    for key in POSTGRES_PASSWORD SECRET_KEY_BASE DATABASE_URL; do
      secret_value="$(kube -n "$NAMESPACE" get secret "$secret_name" -o "jsonpath={.data.$key}" 2>/dev/null || true)"
      [[ -n "$secret_value" ]] || die "Secret $NAMESPACE/$secret_name is missing required key $key; refusing to adopt it"
    done
    printf 'Reusing existing Secret %s/%s\n' "$NAMESPACE" "$secret_name"
    return
  fi

  secret_dir="$tmp_root/secret"
  mkdir -m 700 "$secret_dir"
  openssl rand -hex 32 >"$secret_dir/POSTGRES_PASSWORD"
  openssl rand -hex 64 >"$secret_dir/SECRET_KEY_BASE"
  password="$(<"$secret_dir/POSTGRES_PASSWORD")"
  printf 'ecto://floor_control:%s@postgres:5432/floor_control' "$password" >"$secret_dir/DATABASE_URL"
  chmod 600 "$secret_dir"/*
  kube -n "$NAMESPACE" create secret generic "$secret_name" \
    --dry-run=client -o yaml \
    --from-file=POSTGRES_PASSWORD="$secret_dir/POSTGRES_PASSWORD" \
    --from-file=SECRET_KEY_BASE="$secret_dir/SECRET_KEY_BASE" \
    --from-file=DATABASE_URL="$secret_dir/DATABASE_URL" |
    kube label --local -f - \
    app.kubernetes.io/managed-by=floor-control-kind \
    app.kubernetes.io/part-of=floor-control -o yaml |
    kube apply -f - >/dev/null || die "could not create the labeled Secret atomically"
  printf 'Created Secret %s/%s (values were not printed)\n' "$NAMESPACE" "$secret_name"
}
