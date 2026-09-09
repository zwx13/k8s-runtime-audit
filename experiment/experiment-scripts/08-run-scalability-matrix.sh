#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TENANT_COUNT="${TENANT_COUNT:-2}"

EVENT_COUNTS=(10 50 100 1000)

runs_for_events()
{
  case "$1" in
    10)   echo 30 ;;
    50)   echo 20 ;;
    100)  echo 10 ;;
    1000) echo 10 ;;
    *)    echo 10 ;;
  esac
}

on_interrupt()
{
  echo
  echo "[!] Matrix interrupted."
  exit 130
}

trap on_interrupt INT TERM

FAILED_RUNS=()

for events in "${EVENT_COUNTS[@]}"; do

  RUNS="$(runs_for_events "$events")"

  for run in $(seq 1 "$RUNS"); do

    echo
    echo "============================================================"
    echo " tenants=${TENANT_COUNT}"
    echo " events=${events}"
    echo " run=${run}/${RUNS}"
    echo "============================================================"
    echo

    if "$SCRIPT_DIR/07-scalability.sh" \
        "$TENANT_COUNT" \
        "$events" \
        "$run"; then

      echo "[+] Run completed."

    else
      rc=$?

      if [[ "$rc" -eq 130 || "$rc" -eq 143 ]]; then
        echo "[!] Interrupted."
        exit "$rc"
      fi

      echo "[!] Run failed: tenants=${TENANT_COUNT} events=${events} run=${run}" >&2

      FAILED_RUNS+=("tenants=${TENANT_COUNT},events=${events},run=${run}")
    fi

  done
done

echo
echo "============================================================"
echo "Pilot matrix finished"
echo "============================================================"

if (( ${#FAILED_RUNS[@]} == 0 )); then
  echo "[+] All pilot runs completed successfully."
else
  echo "[!] Failed runs:"

  for failed in "${FAILED_RUNS[@]}"; do
    echo "    $failed"
  done

  exit 1
fi