#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

trap cleanup EXIT

prepare_alert_stream

ensure_base_tenants

info "Creating developer ClusterRole dev..."
cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dev
rules:
- apiGroups: [""]
  resources: ["pods", "configmaps", "secrets"]
  verbs: ["get", "list", "create", "update", "patch", "delete"]
EOF

info "Creating RBs for tenants: one is (accidentally) misconfigured."
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
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: tenant-b-binding
  namespace: ${TB}
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

info "Triggering cross-tenant access attempt: tenant-a user tries to read tenant-b namespace."
expect_fail "${CTX_A} cannot get pods in ${TB}" \
  "$KUBECTL" --context="$CTX_A" get pods -n "$TB"

wait_for_alert_listener