#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Check input args.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

TENANTS="${1:-2}"
COUNT="${2:-1000}"
RUN="${3:-1}"

if (( TENANTS < 2 || TENANTS > 10 )); then
  die "TENANTS must be between 2 and 10"
fi

if (( COUNT < 1 )); then
  die "COUNT must be >= 1"
fi

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Beginning of exp. timing.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

EXPERIMENT_START_NS="$(date +%s%N)"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Results
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

REL_RESULT_DIR="scalability/tenants-${TENANTS}/events-${COUNT}/run-${RUN}-${TIMESTAMP}"

RESULT_DIR="/srv/monitoring-experiments/${REL_RESULT_DIR}"
mkdir -p "$RESULT_DIR"

RESULT_DIR_ABS="$(realpath "$RESULT_DIR")"

RESULTS_FILE="$RESULT_DIR_ABS/workload.log"

TLC_METRICS_FILE_HOST="$RESULT_DIR_ABS/tlc-metrics.csv"
TLC_METRICS_FILE_POD="/experiment-results/$REL_RESULT_DIR/tlc-metrics.csv"

EXPERIMENT_MARKER="/srv/monitoring-experiments/.mt-experiment-active"
TLC_ACTIVE_MARKER="/srv/monitoring-experiments/.mt-tlc-batch-active"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Workload configuration
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ROLES=(
  "view"
  "edit"
  "admin"
  "cluster-admin"
  "dev"
)

RBAC_RESOURCES=(
  "pods"
  "services"
  "configmaps"
  "secrets"
)

RBAC_VERBS=(
  "get"
  "list"
  "watch"
  "create"
  "update"
  "patch"
  "delete"
  "deletecollection"
)

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Tenants
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

TENANT_NAMES=()
TENANT_GROUPS=()
TENANT_CONTEXTS=()

for n in $(seq 1 "$TENANTS"); do
  TENANT_NAMES+=("$(tenant_name "$n")")
  TENANT_GROUPS+=("$(tenant_group "$n")")
  TENANT_CONTEXTS+=("$(tenant_context "$n")")
done

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Cleanup
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

cleanup_scalability()
{
  set +e

  rm -f "$EXPERIMENT_MARKER"

  warn "Cleaning scalability resources..."

  admin delete namespace \
    "${TENANT_NAMES[@]}" \
    --ignore-not-found \
    >/dev/null 2>&1

  admin delete clusterrole \
    dev \
    --ignore-not-found \
    >/dev/null 2>&1

  admin delete clusterrolebinding \
    foo-global-binding \
    --ignore-not-found \
    >/dev/null 2>&1

  warn "Scalability cleanup finished."
}

trap cleanup_scalability EXIT INT TERM

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Random helpers
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

random_role()
{
  printf "%s\n" "${ROLES[@]}" | shuf -n 1
}

random_tenant_index()
{
  echo $((RANDOM % TENANTS))
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# ClusterRole actions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

create_clusterrole()
{
  local i="$1"

  local resources
  local verbs
  local resources_yaml
  local verbs_yaml

  admin delete clusterrole \
    dev \
    --ignore-not-found \
    >/dev/null

  resources="$(
    printf "%s\n" "${RBAC_RESOURCES[@]}" \
      | shuf -n $((RANDOM % 3 + 1)) \
      | paste -sd ',' -
  )"

  verbs="$(
    printf "%s\n" "${RBAC_VERBS[@]}" \
      | shuf -n $((RANDOM % 5 + 1)) \
      | paste -sd ',' -
  )"

  step \
    "$i" \
    "create-clusterrole" \
    "name=dev resources=${resources} verbs=${verbs}"

  resources_yaml="${resources//,/\",\"}"
  verbs_yaml="${verbs//,/\",\"}"

  cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dev
rules:
- apiGroups: [""]
  resources: ["${resources_yaml}"]
  verbs: ["${verbs_yaml}"]
EOF
}

delete_clusterrole()
{
  local i="$1"

  step \
    "$i" \
    "delete-clusterrole" \
    "name=dev"

  admin delete clusterrole \
    dev \
    --ignore-not-found
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# RoleBinding actions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

create_rb()
{
  local i="$1"
  local ns="$2"
  local group="$3"

  local role
  role="$(random_role)"

  step \
    "$i" \
    "create-rb" \
    "ns=${ns} name=tenant-binding group=${group} role=${role}"

  admin delete rolebinding \
    tenant-binding \
    -n "$ns" \
    --ignore-not-found \
    >/dev/null

  cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-binding
  namespace: ${ns}
subjects:
- kind: Group
  name: ${group}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: ${role}
  apiGroup: rbac.authorization.k8s.io
EOF
}

delete_rb()
{
  local i="$1"
  local ns="$2"

  step \
    "$i" \
    "delete-rb" \
    "ns=${ns} name=tenant-binding"

  admin delete rolebinding \
    tenant-binding \
    -n "$ns" \
    --ignore-not-found
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# ClusterRoleBinding actions
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

create_crb()
{
  local i="$1"
  local group="$2"

  local role
  role="$(random_role)"

  step \
    "$i" \
    "create-crb" \
    "name=foo-global-binding group=${group} role=${role}"

  admin delete clusterrolebinding \
    foo-global-binding \
    --ignore-not-found \
    >/dev/null

  cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: foo-global-binding
subjects:
- kind: Group
  name: ${group}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: ${role}
  apiGroup: rbac.authorization.k8s.io
EOF
}

delete_crb()
{
  local i="$1"

  step \
    "$i" \
    "delete-crb" \
    "name=foo-global-binding"

  admin delete clusterrolebinding \
    foo-global-binding \
    --ignore-not-found
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Cross-tenant probe
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

cross_tenant_access()
{
  local i="$1"

  local src_idx
  local dst_idx
  local context
  local target_ns
  local operation
  local rc

  src_idx="$(random_tenant_index)"
  dst_idx="$src_idx"

  while [[ "$dst_idx" -eq "$src_idx" ]]; do
    dst_idx="$(random_tenant_index)"
  done

  context="${TENANT_CONTEXTS[$src_idx]}"
  target_ns="${TENANT_NAMES[$dst_idx]}"

  operation="$(
    printf "%s\n" \
      get \
      list \
      watch \
      patch \
      delete \
      | shuf -n 1
  )"

  step \
    "$i" \
    "cross-tenant-access" \
    "context=${context} operation=${operation} resource=configmap namespace=${target_ns}"

  set +e

  case "$operation" in

    get)
      "$KUBECTL" \
        --context="$context" \
        get configmap cross-tenant-test \
        -n "$target_ns" \
        >/dev/null 2>&1
      ;;

    list)
      "$KUBECTL" \
        --context="$context" \
        get configmaps \
        -n "$target_ns" \
        >/dev/null 2>&1
      ;;

    watch)
      "$KUBECTL" \
        --context="$context" \
        get configmaps \
        -n "$target_ns" \
        --watch-only \
        --request-timeout=1s \
        >/dev/null 2>&1
      ;;

    patch)
      "$KUBECTL" \
        --context="$context" \
        patch configmap cross-tenant-test \
        -n "$target_ns" \
        --type=merge \
        -p '{"metadata":{"labels":{"cross-tenant-probe":"true"}}}' \
        >/dev/null 2>&1
      ;;

    delete)
      "$KUBECTL" \
        --context="$context" \
        delete configmap cross-tenant-test \
        -n "$target_ns" \
        >/dev/null 2>&1
      ;;
  esac

  rc=$?

  set -e

  if [[ "$rc" -eq 0 ]]; then

    info "[$i/$COUNT] cross-tenant ${operation} succeeded"

    if [[ "$operation" == "delete" ]]; then
      admin create configmap \
        cross-tenant-test \
        -n "$target_ns" \
        --from-literal=value=test \
        --dry-run=client \
        -o yaml \
        | admin apply -f - \
        >/dev/null
    fi

  else
    info "[$i/$COUNT] cross-tenant ${operation} denied"
  fi
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Tenant setup
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ensure_scalability_tenants()
{
  local ns

  info "Creating ${TENANTS} tenant namespaces..."

  for ns in "${TENANT_NAMES[@]}"; do

    ensure_tenant_namespace "$ns"

    admin create configmap \
      cross-tenant-test \
      -n "$ns" \
      --from-literal=value=test \
      --dry-run=client \
      -o yaml \
      | admin apply -f -
  done
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Metadata
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

save_experiment_metadata()
{
  {
    echo "tenants=${TENANTS}"
    echo "events=${COUNT}"
    echo "run=${RUN}"
    echo "started=$(date --iso-8601=seconds)"
    echo "tlc_metrics=${TLC_METRICS_FILE_HOST}"

    echo -n "tenant_names="
    printf "%s " "${TENANT_NAMES[@]}"
    echo

    echo -n "tenant_contexts="
    printf "%s " "${TENANT_CONTEXTS[@]}"
    echo

    echo "pipeline_ingest_grace_seconds=${PIPELINE_INGEST_GRACE_SECONDS}"

  } > "$RESULT_DIR_ABS/experiment-info.txt"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Start
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

info "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
info "Scalability experiment"
info "Tenants: ${TENANTS}"
info "Actions: ${COUNT}"
info "Run: ${RUN}"
info "Results: ${RESULT_DIR_ABS}"
info "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

save_experiment_metadata

purge_experiment_streams

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# TLC metrics
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

printf '%s\n' \
  'timestamp,batch_size,fetch_ms,tlc_duration_ms,tlc_non_fetch_ms,exit_code' \
  > "$TLC_METRICS_FILE_HOST"

echo "$TLC_METRICS_FILE_POD" > "$EXPERIMENT_MARKER"

info "TLC metrics enabled:"
info "$TLC_METRICS_FILE_HOST"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Input generation
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

INPUT_GENERATION_START_NS="$(date +%s%N)"

ensure_scalability_tenants

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Workload
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

declare -A ACTION_COUNTS=(
  [create_clusterrole]=0
  [delete_clusterrole]=0
  [create_rb]=0
  [delete_rb]=0
  [create_crb]=0
  [delete_crb]=0
  [cross_tenant_access]=0
)

for i in $(seq 1 "$COUNT"); do

  action=$((RANDOM % 13))

  case "$action" in

    0)
      ((++ACTION_COUNTS[create_clusterrole]))
      create_clusterrole "$i"
      ;;

    1)
      ((++ACTION_COUNTS[delete_clusterrole]))
      delete_clusterrole "$i"
      ;;

    2|3)
      ((++ACTION_COUNTS[create_rb]))

      idx="$(random_tenant_index)"

      create_rb \
        "$i" \
        "${TENANT_NAMES[$idx]}" \
        "${TENANT_GROUPS[$idx]}"
      ;;

    4|5)
      ((++ACTION_COUNTS[delete_rb]))

      idx="$(random_tenant_index)"

      delete_rb \
        "$i" \
        "${TENANT_NAMES[$idx]}"
      ;;

    6)
      ((++ACTION_COUNTS[create_crb]))

      idx="$(random_tenant_index)"

      create_crb \
        "$i" \
        "${TENANT_GROUPS[$idx]}"
      ;;

    7)
      ((++ACTION_COUNTS[delete_crb]))
      delete_crb "$i"
      ;;

    8|9|10|11|12)
      ((++ACTION_COUNTS[cross_tenant_access]))
      cross_tenant_access "$i"
      ;;
  esac
done

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Finish input generation
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

INPUT_GENERATION_END_NS="$(date +%s%N)"

INPUT_GENERATION_DURATION_MS=$(( (INPUT_GENERATION_END_NS - INPUT_GENERATION_START_NS) / 1000000 ))

info "Workload generation complete."
info "Input generation duration: ${INPUT_GENERATION_DURATION_MS} ms"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Wait for pipeline
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

wait_for_pipeline_drain

info "!! Waiting for active TLC batch to finish !!"

while true; do
    if [ ! -f "$TLC_ACTIVE_MARKER" ]; then
        info "No active TLC batch."
        break
    fi

    sleep 1
done

rm -f "$EXPERIMENT_MARKER"
info "TLC metric collection stopped for this run."

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Total experiment duration
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

EXPERIMENT_END_NS="$(date +%s%N)"

EXPERIMENT_TOTAL_MS=$(( (EXPERIMENT_END_NS - EXPERIMENT_START_NS) / 1000000 ))

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# More metrics
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# More metrics
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

TOTAL_TLC_NON_FETCH_MS="$(
    awk -F',' '
        NR > 1 && $5 != "" {
            sum += $5
        }
        END {
            printf "%.0f", sum
        }
    ' "$TLC_METRICS_FILE_HOST"
)"

POST_GENERATION_LAG_MS=$(( EXPERIMENT_TOTAL_MS - INPUT_GENERATION_DURATION_MS ))

TLC_REALTIME_FACTOR="$(
    awk -v tlc="$TOTAL_TLC_NON_FETCH_MS" \
        -v gen="$INPUT_GENERATION_DURATION_MS" '
        BEGIN {
            if (gen > 0)
                printf "%.3f", tlc / gen
            else
                print "NA"
        }
    '
)"

END_TO_END_FACTOR="$(
    awk -v total="$EXPERIMENT_TOTAL_MS" \
        -v gen="$INPUT_GENERATION_DURATION_MS" '
        BEGIN {
            if (gen > 0)
                printf "%.3f", total / gen
            else
                print "NA"
        }
    '
)"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Save summary
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

{
  echo
  echo "actions_performed:"

  for action in "${!ACTION_COUNTS[@]}"; do
    echo "${action}=${ACTION_COUNTS[$action]}"
  done

  echo
  echo "timing:"
  echo "experiment_total_ms=${EXPERIMENT_TOTAL_MS}"
  echo "post_generation_lag_ms=${POST_GENERATION_LAG_MS}"
  echo "realtime_factor=${REALTIME_FACTOR}"
  echo "input_generation_duration_ms=${INPUT_GENERATION_DURATION_MS}"
  echo "pipeline_drain_ms=${PIPELINE_DRAIN_MS}"
  echo "audit_ingestion_grace_ms=${PIPELINE_INGEST_GRACE_MS}"
  echo "audit_consumer_drain_ms=${AUDIT_CONSUMER_DRAIN_MS}"
  echo "tlc_consumer_drain_ms=${TLC_CONSUMER_DRAIN_MS}"

  echo
  echo "finished=$(date --iso-8601=seconds)"

} >> "$RESULT_DIR_ABS/experiment-info.txt"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Experiment is done.
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

info "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
info "Experiment finished"
info "Total experiment time: ${EXPERIMENT_TOTAL_MS} ms"
info "Results: ${RESULT_DIR_ABS}"
info "TLC metrics: ${TLC_METRICS_FILE_HOST}"
info "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"