#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

trap cleanup EXIT

prepare_alert_stream

ensure_base_tenants

info "Creating ClusterRole dev..."
cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dev
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
EOF

info "Creating RoleBinding in ${TA} that references dev"
cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-a-binding
  namespace: ${TA}
subjects:
- kind: Group
  name: ${G_A}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: dev
  apiGroup: rbac.authorization.k8s.io
EOF

sleep 2

start_alert_listener 1

info "Deleting ClusterRole dev. The RoleBinding should become dangling."
admin delete clusterrole dev

wait_for_alert_listener