#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"

# k8s contexts
ADMIN_CTX="${ADMIN_CTX:-kubernetes-admin@kubernetes}"
CTX_A="${CTX_A:-tenant-a-user@kubernetes}"
CTX_B="${CTX_B:-tenant-b-user@kubernetes}"

# tenant namespaces and groups
TA="${TA:-tenant-a}"
TB="${TB:-tenant-b}"
G_A="${G_A:-tenant-a}"
G_B="${G_B:-tenant-b}"

# platform group used for cluster-wide examples
PLATFORM_GROUP="${PLATFORM_GROUP:-kubeadm:cluster-admins}"

# monitoring deployment namespace
MON_NS="${MON_NS:-default}"

# NATS settings
NATS_BOX_DEPLOY="${NATS_BOX_DEPLOY:-nats-box}"
ALERT_STREAM="${ALERT_STREAM:-MT_ALERTS}"
ALERT_SUBJECT="${ALERT_SUBJECT:-audit.mt.alerts}"
ALERT_WAIT_SECONDS="${ALERT_WAIT_SECONDS:-20}"
ALERT_OUT="${ALERT_OUT:-/tmp/mt-alerts.out}"
ALERT_SUB_PID=""

OK_IMAGE="${OK_IMAGE:-nginx}"

info() { echo "[+]" "$*"; }
warn() { echo "[!]" "$*" >&2; }
die() { echo "[x]" "$*" >&2; exit 1; }

admin() 
{
  "$KUBECTL" --context="$ADMIN_CTX" "$@"
}

run() 
{
  info "$*"
  "$@"
}

expect_fail() 
{
  local desc="$1"
  shift

  info "EXPECT FAILURE: ${desc}"
  if "$@"; then
    warn "Command unexpectedly succeeded: ${desc}"
  else
    info "Command failed as expected: ${desc}"
  fi
}

nats_box_exec() 
{
  "$KUBECTL" exec -n "$MON_NS" "deploy/${NATS_BOX_DEPLOY}" -- "$@"
}

purge_alerts() 
{
  info "Purging NATS alert stream: ${ALERT_STREAM}"

  if nats_box_exec nats stream purge "$ALERT_STREAM" --force >/dev/null 2>&1; then
    info "Alert stream purged."
  else
    warn "Could not purge alert stream with --force."
    warn "Trying non-interactive yes pipe..."

    if nats_box_exec sh -c "yes | nats stream purge ${ALERT_STREAM}" >/dev/null 2>&1; then
      info "Alert stream purged."
    else
      warn "Could not purge alert stream. Continuing anyway."
    fi
  fi
}

start_alert_listener() 
{
  info "Starting NATS alert listener on subject: ${ALERT_SUBJECT}"
  rm -f "$ALERT_OUT"

  (
    nats_box_exec nats sub "$ALERT_SUBJECT" \
      --count=1 \
      --timeout="${ALERT_WAIT_SECONDS}s" \
      --raw
  ) > "$ALERT_OUT" 2>&1 &

  ALERT_SUB_PID="$!"

  sleep 1
}

wait_for_alert_listener() 
{
  info "Waiting for alert listener..."

  if [[ -z "$ALERT_SUB_PID" ]]; then
    warn "No alert listener was started."
    return 0
  fi

  if wait "$ALERT_SUB_PID"; then
    info "Alert listener finished."
  else
    warn "Alert listener finished with non-zero status."
  fi

  echo
  info "Alert output:"
  echo "------------------------------------------------------------"
  cat "$ALERT_OUT" || true
  echo "------------------------------------------------------------"
  echo
}

prepare_alert_stream() 
{
  purge_alerts
  sleep 1
}

ensure_base_tenants() 
{
  info "Creating tenant namespaces ${TA} and ${TB}..."
  cat <<EOF | admin apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${TA}
  labels:
    tenant: ${TA}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${TB}
  labels:
    tenant: ${TB}
EOF
}

cleanup() 
{
  set +e
  warn "Cleaning tenant namespaces and test resources..."

  admin delete pod --all -n "$TA" --ignore-not-found >/dev/null 2>&1
  admin delete pod --all -n "$TB" --ignore-not-found >/dev/null 2>&1

  admin delete rolebinding --all -n "$TA" --ignore-not-found >/dev/null 2>&1
  admin delete rolebinding --all -n "$TB" --ignore-not-found >/dev/null 2>&1

  admin delete clusterrole dev --ignore-not-found >/dev/null 2>&1

  admin delete clusterrolebinding \
    foo-global-binding \
    --ignore-not-found >/dev/null 2>&1

  admin delete namespace "$TA" "$TB" --ignore-not-found >/dev/null 2>&1

  warn "Cleanup finished."
}