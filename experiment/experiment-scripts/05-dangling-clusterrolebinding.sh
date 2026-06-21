#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

trap cleanup EXIT

RESULT_DIR="../experiment-results/05/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_DIR"

RESULTS_FILE="$RESULT_DIR/script-output-and-alerts.log"
AUDIT_FILE="$RESULT_DIR/audit-events.jsonl"

prepare_alert_stream

ensure_base_tenants

info2file "Creating temporary ClusterRole dev..."
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

info2file "Creating ClusterRoleBinding that references foo-global-binding..."
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

info2file "Deleting ClusterRole dev. The ClusterRoleBinding should become dangling."
admin delete clusterrole dev

start_alert_listener 1

wait_for_alert_listener

save_alerts_to_file

extract_audit_events_for_alerts