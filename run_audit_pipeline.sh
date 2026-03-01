#!/bin/bash

set -euo pipefail

# before exiting, kill every process in current process group
cleanup() {
  echo
  echo "[!] Stopping all services."
  trap - INT TERM        # prevent re-entry
  kill 0                 # terminate process group
}

trap cleanup INT TERM

# start venv
echo "[+] Activating Python virtual environment..."
source python_audit/.venv/bin/activate

# start the webhook receiver in the background
echo "[+] Starting webhook receiver..."
python3 python_audit/audit_webhook_receiver.py &
RECEIVER_PID=$!

RECEIVER_URL="http://127.0.0.1:9770/healthz"

for i in $(seq 1 50); do

    if ! kill -0 "$RECEIVER_PID" 2>/dev/null; then
        echo "[!] Receiver process exited during startup."
        exit 1
    fi

    if curl -sf --max-time 1 "$RECEIVER_URL" >/dev/null 2>&1; then
        echo "[+] Receiver is healthy."
        break
    fi

    sleep 0.1
done

if ! curl -sfS --max-time 1 "$RECEIVER_URL" >/dev/null; then
    echo "[!] Receiver did not become healthy."
    exit 1
fi

# wait so FastAPI server is up
sleep 3

# start the partitioning/filtering script
echo "[+] Starting partitioning nodes/namespaces script..."
python3 python_audit/multitenancy.py | while read -r line; do
    echo "$line"
    if [[ "$line" == "READY" ]]; then
        echo "[+] Partitioning script is ready."
        break
    fi
done &
PARTITIONING_PI1=$!

# start the kv script
echo "[+] Starting saving t o kv script..."
python3 python_audit/mt_state_store.py | while read -r line; do
    echo "$line"
    if [[ "$line" == "READY" ]]; then
        echo "[+] KV script is ready."
        break
    fi
done &
PARTITIONING_PID2=$!

# start the alert script
echo "[+] Starting partitioning nodes/namespaces script..."
python3 python_audit/alerts.py | while read -r line; do
    echo "$line"
    if [[ "$line" == "READY" ]]; then
        echo "[+] Alerts script is ready."
        break
    fi
done &
PARTITIONING_PID3=$!

# start the Java NATS consumer in the background
# mvn package should already be done so the jar is built
echo "[+] Starting Java NATS consumer..."
java -cp "java-tlamonitor-audit/target/java-tlamonitor-audit-1.0-SNAPSHOT.jar:CommunityModules.jar:tla2tools.jar" tlc2.Main \
    tla_specs/MTSpec/MC_MT_Audit_RBAC_Trace_Extended.tla \
    tla_specs/MTSpec/MC_MT_Audit_RBAC_Trace_Extended.cfg \
    CommunityModules.jar \
    tla2tools.jar \
&
JAVA_PID=$!

# keep supervisor script running while services run
wait
