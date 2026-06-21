#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/common.sh"

trap cleanup EXIT

RESULT_DIR="../experiment-results/04/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_DIR"

RESULTS_FILE="$RESULT_DIR/script-output-and-alerts.log"
AUDIT_FILE="$RESULT_DIR/audit-events.jsonl"

prepare_alert_stream

ensure_base_tenants

info2file "Creating invalid ClusterRoleBinding that grants cluster-wide access to tenant group ${G_A}..."
cat <<EOF | admin apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: foo-global-binding
subjects:
- kind: Group
  name: ${G_A}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
EOF

start_alert_listener 1

wait_for_alert_listener

save_alerts_to_file

extract_audit_events_for_alerts