#!/usr/bin/env bash

set -euo pipefail

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Kubernetes
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

KUBECTL="${KUBECTL:-kubectl}"

ADMIN_CTX="${ADMIN_CTX:-kubernetes-admin@kubernetes}"
CTX_A="${CTX_A:-tenant-a-user@kubernetes}"
CTX_B="${CTX_B:-tenant-b-user@kubernetes}"

MON_NS="${MON_NS:-default}"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Base tenants / groups
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

TA="${TA:-tenant-a}"
TB="${TB:-tenant-b}"

G_A="${G_A:-tenant-a}"
G_B="${G_B:-tenant-b}"

PLATFORM_GROUP="${PLATFORM_GROUP:-kubeadm:cluster-admins}"

OK_IMAGE="${OK_IMAGE:-nginx}"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# NATS
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

NATS_BOX_DEPLOY="${NATS_BOX_DEPLOY:-nats-box}"

AUDIT_STREAM="${AUDIT_STREAM:-AUDIT}"
AUDIT_MT_STREAM="${AUDIT_MT_STREAM:-AUDIT_MT}"
ALERT_STREAM="${ALERT_STREAM:-MT_ALERTS}"

ALERT_SUBJECT="${ALERT_SUBJECT:-audit.mt.alerts}"

# AUDIT -> AUDIT_MT
AUDIT_MT_FILTER_DURABLE="${AUDIT_MT_FILTER_DURABLE:-audit-mt-filter}"

# AUDIT_MT -> TLC
TLA_DURABLE="${TLA_DURABLE:-audit-mt-tla-filter}"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Pipeline synchronization
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

PIPELINE_INGEST_GRACE_SECONDS="${PIPELINE_INGEST_GRACE_SECONDS:-2}"

PIPELINE_POLL_SECONDS="${PIPELINE_POLL_SECONDS:-1}"

# Failsafe only.
PIPELINE_TIMEOUT_SECONDS="${PIPELINE_TIMEOUT_SECONDS:-120}"

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Alert configuration
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

ALERT_WAIT_SECONDS="${ALERT_WAIT_SECONDS:-70}"
ALERT_OUT="${ALERT_OUT:-/tmp/mt-alerts.out}"
ALERT_SUB_PID=""

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Logging
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

info()
{
  echo "[+]" "$*"
}

info2file()
{
  echo "[+]" "$*"
  echo "[+]" "$*" >> "$RESULTS_FILE"
}

warn()
{
  echo "[!]" "$*" >&2
}

die()
{
  echo "[x]" "$*" >&2
  exit 1
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Tenant helpers
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

tenant_name()
{
  echo "tenant-$1"
}

tenant_group()
{
  echo "tenant-$1"
}

tenant_context()
{
  echo "tenant-$1-user@kubernetes"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Kubernetes helpers
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

admin()
{
  "$KUBECTL" \
    --context="$ADMIN_CTX" \
    "$@"
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
    warn "Command WRONGLY succeeded: ${desc}"
  else
    info "Command failed as expected: ${desc}"
  fi
}

ensure_tenant_namespace()
{
  local tenant="$1"

  cat <<EOF | admin apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${tenant}
  labels:
    tenant: ${tenant}
EOF
}

ensure_base_tenants()
{
  info "Creating tenant namespaces ${TA} and ${TB}..."

  ensure_tenant_namespace "$TA"
  ensure_tenant_namespace "$TB"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# NATS helpers
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

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
    warn "Could not purge alert stream."
  fi
}

purge_experiment_streams()
{
  local stream

  for stream in $AUDIT_STREAM $AUDIT_MT_STREAM $ALERT_STREAM; do
    info "Purging NATS stream: ${stream}"

    if ! nats_box_exec nats stream purge "$stream" --force >/dev/null 2>&1; then
      die "Could not purge ${stream}."
    fi
  done

  info "Experiment streams purged."
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Consumer synchronization
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

wait_for_consumer_drain()
{
  local stream="$1"
  local consumer="$2"

  local start_time
  local state
  local pending
  local ack_pending

  start_time="$(date +%s)"

  info "Waiting for ${consumer} on ${stream}..."

  while true; do

    state="$(nats_box_exec nats consumer info "$stream" "$consumer" --json)"

    pending="$(jq -r '.num_pending' <<< "$state")"
    ack_pending="$(jq -r '.num_ack_pending' <<< "$state")"

    info "${consumer}: pending=${pending}, ack_pending=${ack_pending}"

    if [[ "$pending" -eq 0 && "$ack_pending" -eq 0 ]]; then
      info "${consumer} drained."
      return 0
    fi

    if (( $(date +%s) - start_time >= PIPELINE_TIMEOUT_SECONDS )); then
      die "Timed out waiting for ${consumer} on ${stream}."
    fi

    sleep "$PIPELINE_POLL_SECONDS"
  done
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Full pipeline synchronization + timing
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

wait_for_pipeline_drain()
{
  local start_ns
  local end_ns
  local stage_start_ns

  start_ns="$(date +%s%N)"

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Stage 0:
  # kube-apiserver audit webhook -> AUDIT
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  stage_start_ns="$(date +%s%N)"

  info "Waiting ${PIPELINE_INGEST_GRACE_SECONDS}s for audit webhook delivery..."

  sleep "$PIPELINE_INGEST_GRACE_SECONDS"

  PIPELINE_INGEST_GRACE_MS=$(( ($(date +%s%N) - stage_start_ns) / 1000000 ))

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Stage 1:
  # AUDIT -> audit-mt-filter -> AUDIT_MT
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  stage_start_ns="$(date +%s%N)"

  wait_for_consumer_drain "$AUDIT_STREAM" "$AUDIT_MT_FILTER_DURABLE"

  AUDIT_CONSUMER_DRAIN_MS=$(( ($(date +%s%N) - stage_start_ns) / 1000000 ))

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Stage 2:
  # AUDIT_MT -> audit-mt-tla-filter -> TLC
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  stage_start_ns="$(date +%s%N)"

  wait_for_consumer_drain "$AUDIT_MT_STREAM" "$TLA_DURABLE"

  TLC_CONSUMER_DRAIN_MS=$(( ($(date +%s%N) - stage_start_ns) / 1000000 ))

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Total
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

  end_ns="$(date +%s%N)"

  PIPELINE_DRAIN_MS=$(( (end_ns - start_ns) / 1000000 ))

  info "Pipeline drained."
  info "Audit webhook grace: ${PIPELINE_INGEST_GRACE_MS} ms"
  info "AUDIT consumer drain: ${AUDIT_CONSUMER_DRAIN_MS} ms"
  info "TLC consumer drain: ${TLC_CONSUMER_DRAIN_MS} ms"
  info "Total pipeline drain: ${PIPELINE_DRAIN_MS} ms"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Alert helpers used by experiments 1-6
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

start_alert_listener()
{
  local count="$1"

  info "Starting NATS alert listener on ${ALERT_SUBJECT}"

  rm -f "$ALERT_OUT"

  (
    nats_box_exec nats sub "$ALERT_SUBJECT" --count="$count" \
      --wait="${ALERT_WAIT_SECONDS}s" \
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

  wait "$ALERT_SUB_PID" || true

  echo
  cat "$ALERT_OUT" || true
  echo
}

save_alerts_to_file()
{
  {
    echo
    echo "~~~~~~~~~~~~~~~~ ALERTS ~~~~~~~~~~~~~~~~"
    cat "$ALERT_OUT" 2>/dev/null || true
  } >> "$RESULTS_FILE"
}

prepare_alert_stream()
{
  purge_alerts
  sleep 1
}

extract_audit_events_for_alerts()
{
  local ids_file

  ids_file="$(mktemp)"

  grep -oE \
    '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    "$RESULTS_FILE" \
    > "$ids_file" || true

  sudo grep -Ff \
    "$ids_file" \
    /var/log/kubernetes/audit.log \
    | jq -c . \
    > "$AUDIT_FILE" || true

  rm -f "$ids_file"

  info "Saved $(wc -l < "$AUDIT_FILE") audit events."
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Experiment logging
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

step()
{
  local i="$1"
  local action="$2"

  shift 2

  local msg="[$i/$COUNT] action=${action} $*"

  info "$msg"
  echo "$msg" >> "$RESULTS_FILE"
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Cleanup used by experiments 1-6
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

cleanup()
{
  set +e

  warn "Cleaning tenant namespaces and test resources..."
  admin delete namespace "$TA" "$TB" --ignore-not-found >/dev/null 2>&1
  admin delete clusterrole dev --ignore-not-found >/dev/null 2>&1
  admin delete clusterrolebinding foo-global-binding --ignore-not-found >/dev/null 2>&1
  warn "Cleanup finished."
}