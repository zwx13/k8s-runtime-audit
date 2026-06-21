#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "$0")/common.sh"
trap cleanup EXIT

COUNT="${1:-50}"

RESULT_DIR="../experiment-results/06/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_DIR"

RESULTS_FILE="$RESULT_DIR/script-output-and-alerts.log"
AUDIT_FILE="$RESULT_DIR/audit-events.jsonl"

ROLES=("view" "edit" "admin" "cluster-admin" "dev")
VERBS=("get" "list" "watch" "create" "update" "patch" "delete" "deletecollection")
RESOURCES=("pods" "services" "configmaps" "secrets")

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

create_clusterrole()
{
    local resources resources_yaml
    local verbs verbs_yaml

    admin delete clusterrole dev --ignore-not-found

    resources="$(printf "%s\n" "${RESOURCES[@]}" | shuf -n $((RANDOM % 3 + 1)) | paste -sd ',' -)"
    verbs="$(printf "%s\n" "${VERBS[@]}" | shuf -n $((RANDOM % 5 + 1)) | paste -sd ',' -)"

    step "$i" "create-clusterrole" "name=dev resources=${resources} verbs=${verbs}"

    resources_yaml=$(echo "$resources" | sed 's/,/","/g')
    verbs_yaml=$(echo "$verbs" | sed 's/,/","/g')

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
    step "$i" "delete-clusterrole" "name=dev"
    admin delete clusterrole dev --ignore-not-found
}

create_rb() 
{
  local i="$1"
  local ns="$2"
  local group="$3"
  local name="$4"
  local role

  role="$(random_role)"

  step "$i" "create-rb" "ns=${ns} name=${name} group=${group} role=${role}"

  admin delete rolebinding "$name" -n "$ns" --ignore-not-found

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
  local name="$3"

  step "$i" "delete-rb" "ns=${ns} name=${name}"

  admin delete rolebinding "$name" -n "$ns" --ignore-not-found
}

create_crb() 
{
  local i="$1"
  local group="$2"
  local name="foo-global-binding"
  local role

  role="$(random_role)"

  step "$i" "create-crb" "name=${name} group=${group} role=${role}"

  admin delete clusterrolebinding "$name" --ignore-not-found

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
  local name="foo-global-binding"

  step "$i" "delete-crb" "name=${name}"

  admin delete clusterrolebinding "$name" --ignore-not-found
}

cross_tenant_access() 
{
  local i="$1"
  local verb="$2"
  local resource="$3"

  step "$i" "cross-tenant-access" "context=${CTX_A} resource=${resource} namespace=${TB}"

  set +e
  "$KUBECTL" --context="$CTX_A" "$verb" "$resource" -n "$TB" >/dev/null 2>&1
  local rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    warn "[$i/$COUNT] cross-tenant ${verb} ${resource} unexpectedly succeeded"
  else
    info "[$i/$COUNT] cross-tenant ${verb} ${resource} failed as expected"
  fi
}

prepare_alert_stream

start_alert_listener 50

ensure_base_tenants

for i in $(seq 1 "$COUNT"); do
  action=$(( RANDOM % 13 ))

  case "$action" in
    0) create_clusterrole "$i" ;;
    1) delete_clusterrole "$i" ;;
    2) create_rb "$i" "$TA" "$G_A" "tenant-a-binding" ;;
    3) create_rb "$i" "$TB" "$G_B" "tenant-b-binding" ;;
    4) delete_rb "$i" "$TA" "tenant-a-binding" ;;
    5) delete_rb "$i" "$TB" "tenant-b-binding" ;;
    6) create_crb "$i" "$G_A" ;;
    7) delete_crb "$i" ;;
    8|9|10|11|12) cross_tenant_access "$i" "$(random_verb)" "$(random_resource)" ;;
  esac

  sleep 1
done

wait_for_alert_listener

save_alerts_to_file

extract_audit_events_for_alerts