#!/bin/bash

# start venv
echo "[+] Activating Python virtual environment..."
source python_audit/.venv/bin/activate

# start the webhook receiver in the background
echo "[+] Starting webhook receiver..."
python3 python_audit/audit_webhook_receiver.py &
RECEIVER_PID=$!

# wait so FastAPI server is up
sleep 3

# start the partitioning/filtering script
echo "[+] Starting partitioning nodes/namespaces script..."
python3 python_audit/ns-per-node.py | while read -r line; do
    echo "$line"
    if [[ "$line" == "READY" ]]; then
        echo "[+] Partitioning script is ready."
        break
    fi
done &
PARTITIONING_PID=$!

# start the Java NATS consumer in the background
# mvn package should already be done so the jar is built
echo "[+] Starting Java NATS consumer..."
java -cp "java-tlamonitor-audit/target/java-tlamonitor-audit-1.0-SNAPSHOT.jar:tla2tools.jar" tlc2.Main \
    node_isolation.tla \
    node_isolation.cfg \
    tla2tools.jar &
JAVA_PID=$!



# trap Ctrl+C to kill all background processes
trap "echo; echo '[!] Stopping all services.'; kill $RECEIVER_PID $PARTITIONING_PID $JAVA_PID; exit 0" SIGINT

# wait for all background processes
wait $RECEIVER_PID $PARTITIONING_PID $JAVA_PID
