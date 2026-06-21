#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

trap cleanup EXIT

prepare_alert_stream

ensure_base_tenants

info "Creating temporary ClusterRole dev..."
cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dev
rules:
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["get", "list"]
EOF

info "Creating ClusterRoleBinding that references foo-global-binding..."
cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: foo-global-binding
subjects:
- kind: Group
  name: ${PLATFORM_GROUP}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: dev
  apiGroup: rbac.authorization.k8s.io
EOF

sleep 2

info "Deleting ClusterRole dev. The ClusterRoleBinding should become dangling."
admin delete clusterrole dev

start_alert_listener 1

wait_for_alert_listener