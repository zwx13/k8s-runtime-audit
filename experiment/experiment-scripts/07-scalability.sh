#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/common.sh"

TENANTS="${1:-2}"
COUNT="${2:-1000}"
RUN="${3:-1}"

if (( TENANTS < 2 || TENANTS > 10 )); then
  die "TENANTS must be between 2 and 10"
fi

if (( COUNT < 1 )); then
  die "COUNT must be >= 1"
fi

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Results
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

RESULT_DIR="$SCRIPT_DIR/../experiment-results/scalability/tenants-${TENANTS}_events-${COUNT}_run-${RUN}"

mkdir -p "$RESULT_DIR"

RESULT_DIR_ABS="$(realpath "$RESULT_DIR")"

RESULTS_FILE="$RESULT_DIR_ABS/workload.log"
TLC_METRICS_FILE="$RESULT_DIR_ABS/tlc-metrics.csv"

EXPERIMENT_MARKER="/tmp/mt-experiment-active"

TLA_MODEL="$SCRIPT_DIR/../../tla_specs/UpdatedMTSpec/MC_MT_Audit_RBAC_Trace_1.tla"


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Workload configuration
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ROLES=("view" "edit" "admin" "cluster-admin" "dev")

VERBS=(
  "get"
  "list"
  "watch"
  "create"
  "update"
  "patch"
  "delete"
  "deletecollection"
)

RESOURCES=(
  "pods"
  "services"
  "configmaps"
  "secrets"
)


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Tenant universe
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

TENANT_NAMES=()
TENANT_GROUPS=()
TENANT_CONTEXTS=()

for n in $(seq 1 "$TENANTS"); do
  TENANT_NAMES+=("$(tenant_name "$n")")
  TENANT_GROUPS+=("$(tenant_group "$n")")
  TENANT_CONTEXTS+=("$(tenant_context "$n")")
done


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Cleanup
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

cleanup_scalability()
{
  set +e

  rm -f "$EXPERIMENT_MARKER"

  warn "Cleaning scalability experiment resources..."

  for ns in "${TENANT_NAMES[@]}"; do

    admin delete pod \
      --all \
      -n "$ns" \
      --ignore-not-found \
      >/dev/null 2>&1

    admin delete rolebinding \
      --all \
      -n "$ns" \
      --ignore-not-found \
      >/dev/null 2>&1

    admin delete namespace \
      "$ns" \
      --ignore-not-found \
      >/dev/null 2>&1

  done

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


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Random helpers
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

random_verb()
{
  printf "%s\n" "${VERBS[@]}" | shuf -n 1
}

random_resource()
{
  printf "%s\n" "${RESOURCES[@]}" | shuf -n 1
}

random_role()
{
  printf "%s\n" "${ROLES[@]}" | shuf -n 1
}

random_tenant_index()
{
  echo $((RANDOM % TENANTS))
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# ClusterRole operations
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

create_clusterrole()
{
  local i="$1"

  local resources
  local resources_yaml
  local verbs
  local verbs_yaml

  admin delete clusterrole dev --ignore-not-found

  resources="$(
    printf "%s\n" "${RESOURCES[@]}" |
    shuf -n $((RANDOM % 3 + 1)) |
    paste -sd ',' -
  )"

  verbs="$(
    printf "%s\n" "${VERBS[@]}" |
    shuf -n $((RANDOM % 5 + 1)) |
    paste -sd ',' -
  )"

  step "$i" \
    "create-clusterrole" \
    "name=dev resources=${resources} verbs=${verbs}"

  resources_yaml="$(echo "$resources" | sed 's/,/","/g')"
  verbs_yaml="$(echo "$verbs" | sed 's/,/","/g')"

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

  step "$i" \
    "delete-clusterrole" \
    "name=dev"

  admin delete clusterrole \
    dev \
    --ignore-not-found
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# RoleBinding operations
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

create_rb()
{
  local i="$1"
  local ns="$2"
  local group="$3"

  local name="tenant-binding"
  local role

  role="$(random_role)"

  step "$i" \
    "create-rb" \
    "ns=${ns} name=${name} group=${group} role=${role}"

  admin delete rolebinding \
    "$name" \
    -n "$ns" \
    --ignore-not-found

  cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${name}
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

  local name="tenant-binding"

  step "$i" \
    "delete-rb" \
    "ns=${ns} name=${name}"

  admin delete rolebinding \
    "$name" \
    -n "$ns" \
    --ignore-not-found
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# ClusterRoleBinding operations
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

create_crb()
{
  local i="$1"
  local group="$2"

  local name="foo-global-binding"
  local role

  role="$(random_role)"

  step "$i" \
    "create-crb" \
    "name=${name} group=${group} role=${role}"

  admin delete clusterrolebinding \
    "$name" \
    --ignore-not-found

  cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${name}
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

  step "$i" \
    "delete-crb" \
    "name=foo-global-binding"

  admin delete clusterrolebinding \
    foo-global-binding \
    --ignore-not-found
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Cross-tenant access
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

cross_tenant_access()
{
  local i="$1"

  local src_idx
  local dst_idx
  local context
  local target_ns
  local verb
  local resource

  src_idx="$(random_tenant_index)"
  dst_idx="$src_idx"

  while [ "$dst_idx" -eq "$src_idx" ]; do
    dst_idx="$(random_tenant_index)"
  done

  context="${TENANT_CONTEXTS[$src_idx]}"
  target_ns="${TENANT_NAMES[$dst_idx]}"

  verb="$(random_verb)"
  resource="$(random_resource)"

  step "$i" \
    "cross-tenant-access" \
    "context=${context} verb=${verb} resource=${resource} namespace=${target_ns}"

  set +e

  "$KUBECTL" \
    --context="$context" \
    "$verb" \
    "$resource" \
    -n "$target_ns" \
    >/dev/null 2>&1

  local rc=$?

  set -e

  if [ "$rc" -eq 0 ]; then
    warn "[$i/$COUNT] cross-tenant ${verb} ${resource} unexpectedly succeeded"
  else
    info "[$i/$COUNT] cross-tenant ${verb} ${resource} failed as expected"
  fi
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Tenant setup
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ensure_scalability_tenants()
{
  info "Creating ${TENANTS} tenant namespaces..."

  for ns in "${TENANT_NAMES[@]}"; do
    ensure_tenant_namespace "$ns"
  done
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# NATS cleanup
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

purge_experiment_streams()
{
  info "Purging AUDIT stream..."

  if nats_box_exec nats stream purge AUDIT --force \
    >/dev/null 2>&1; then
    info "AUDIT stream purged."
  else
    warn "Could not purge AUDIT stream."
  fi


  info "Purging AUDIT_MT stream..."

  if nats_box_exec nats stream purge AUDIT_MT --force \
    >/dev/null 2>&1; then
    info "AUDIT_MT stream purged."
  else
    warn "Could not purge AUDIT_MT stream."
  fi
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Metadata
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

save_experiment_metadata()
{
  {
    echo "tenants=${TENANTS}"
    echo "events=${COUNT}"
    echo "run=${RUN}"
    echo "started=$(date --iso-8601=seconds)"
    echo "tlc_metrics=${TLC_METRICS_FILE}"

    echo -n "tenant_names="
    printf "%s " "${TENANT_NAMES[@]}"
    echo

    echo -n "tenant_contexts="
    printf "%s " "${TENANT_CONTEXTS[@]}"
    echo

  } > "$RESULT_DIR_ABS/experiment-info.txt"
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Experiment setup
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

info "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
info "Scalability experiment"
info "Tenants: ${TENANTS}"
info "Actions: ${COUNT}"
info "Run: ${RUN}"
info "Results: ${RESULT_DIR_ABS}"
info "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

save_experiment_metadata

# Remove all setup events before measurement starts.
purge_experiment_streams

ensure_scalability_tenants

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Enable TLC metrics
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

echo "$TLC_METRICS_FILE" > "$EXPERIMENT_MARKER"

info "TLC metrics enabled:"
info "$TLC_METRICS_FILE"


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Workload
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

for i in $(seq 1 "$COUNT"); do

  action=$((RANDOM % 13))

  case "$action" in

    0)
      create_clusterrole "$i"
      ;;

    1)
      delete_clusterrole "$i"
      ;;

    2|3)
      idx="$(random_tenant_index)"

      create_rb \
        "$i" \
        "${TENANT_NAMES[$idx]}" \
        "${TENANT_GROUPS[$idx]}"
      ;;

    4|5)
      idx="$(random_tenant_index)"

      delete_rb \
        "$i" \
        "${TENANT_NAMES[$idx]}"
      ;;

    6)
      idx="$(random_tenant_index)"

      create_crb \
        "$i" \
        "${TENANT_GROUPS[$idx]}"
      ;;

    7)
      delete_crb "$i"
      ;;

    8|9|10|11|12)
      cross_tenant_access "$i"
      ;;

  esac

done


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Finish
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

info "Workload generation complete."

# Temporary drain period.
# Should be changed.
sleep 6

rm -f "$EXPERIMENT_MARKER"

info "TLC metric collection disabled."

echo "finished=$(date --iso-8601=seconds)" \
  >> "$RESULT_DIR_ABS/experiment-info.txt"

info "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
info "Experiment finished"
info "Results: ${RESULT_DIR_ABS}"
info "TLC metrics: ${TLC_METRICS_FILE}"
info "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"