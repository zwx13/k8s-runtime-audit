#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

trap cleanup EXIT

prepare_alert_stream

ensure_base_tenants

info "Creating invalid RoleBinding to cluster-admin inside namespace ${TA}..."
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
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

start_alert_listener

wait_for_alert_listener