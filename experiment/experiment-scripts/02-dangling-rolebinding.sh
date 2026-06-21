#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

trap cleanup EXIT

RESULT_DIR="../experiment-results/02/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_DIR"

RESULTS_FILE="$RESULT_DIR/script-output-and-alerts.log"
AUDIT_FILE="$RESULT_DIR/audit-events.jsonl"

prepare_alert_stream

ensure_base_tenants

info2file "Creating ClusterRole dev..."
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

info2file "Creating RoleBinding in ${TA} that references dev"
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

info2file "Deleting ClusterRole dev. The RoleBinding should become dangling."
admin delete clusterrole dev

wait_for_alert_listener

save_alerts_to_file

extract_audit_events_for_alerts