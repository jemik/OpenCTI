#!/usr/bin/env bash
set -euo pipefail

# install_noop_content.sh
# Creates a NoOp executor + sample injectors + scenario + steps in OpenBAS, safely.
#
# Usage:
#   OPENBAS_HOST="http://127.0.0.1:4000" OPENBAS_TOKEN="..." ./install_noop_content.sh [--no-run] [--no-telemetry]
#
# Options:
#   --no-run         : Do not trigger a test inject run (default: script triggers a test run)
#   --no-telemetry   : Do not index synthetic telemetry to Elasticsearch (default: will index if ES_URL provided)
#
# Environment variables:
#   OPENBAS_HOST    : e.g. http://127.0.0.1:4000
#   OPENBAS_TOKEN   : OpenBAS API token (Profile -> API access)
#   ES_URL          : optional, e.g. http://elasticsearch:9200 (if you want telemetry inserted)
#   ES_INDEX        : optional, default "openbas-simulated"
#   PLAYER_HOSTNAME : optional name for created player
#   PLAYER_IP       : optional ip for created player
#
# The script is conservative and idempotent (re-creating objects if they already exist is safe).

: "${OPENBAS_HOST:=${OPENBAS_HOST:-http://127.0.0.1:4000}}"
: "${OPENBAS_TOKEN:=${OPENBAS_TOKEN:-}}"
ES_URL="${ES_URL:-http://elasticsearch:9200}"
ES_INDEX="${ES_INDEX:-openbas-simulated}"
PLAYER_HOSTNAME="${PLAYER_HOSTNAME:-host-win10-1}"
PLAYER_IP="${PLAYER_IP:-10.0.0.21}"

if [[ -z "$OPENBAS_TOKEN" ]]; then
  echo "ERROR: OPENBAS_TOKEN must be set. Export OPENBAS_TOKEN or pass env var."
  exit 1
fi

NO_RUN=false
NO_TELEMETRY=false
while [[ "${1:-}" != "" ]]; do
  case "$1" in
    --no-run) NO_RUN=true ;;
    --no-telemetry) NO_TELEMETRY=true ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
  shift
done

# dependencies
for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
done

UUIDGEN() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    cat /proc/sys/kernel/random/uuid 2>/dev/null || (head -c16 /dev/urandom | xxd -p -c16)
  fi
}

# helper: POST JSON, print pretty or raw
api_post() {
  local url="$1"; local datafile="$2"
  curl -sS -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" \
    --data-binary @"${datafile}" \
    "${url}"
}

api_post_json() {
  local url="$1"; local json="$2"
  curl -sS -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" \
    --data "$json" \
    "${url}"
}

api_get() {
  local url="$1"
  curl -sS -H "Authorization: Bearer ${OPENBAS_TOKEN}" \
    "${url}"
}

echo
echo "Connecting to OpenBAS at: ${OPENBAS_HOST}"
if ! curl -fsS "${OPENBAS_HOST}/actuator/health" >/dev/null 2>&1; then
  echo "WARNING: Could not reach ${OPENBAS_HOST}/actuator/health. Continuing but check connectivity."
fi

# -----------------------
# 1) Create NoOp executor
# -----------------------
echo
echo "==> 1) Creating NoOp executor (idempotent)"

NOOP_EXEC_KEY="noop-executor"
EXISTING_EXEC_JSON="$(api_get "${OPENBAS_HOST}/api/executors" || true)"
NOOP_ID=""
if echo "${EXISTING_EXEC_JSON}" | jq -e --arg k "${NOOP_EXEC_KEY}" '.[] | select(.key == $k) | .id' >/dev/null 2>&1; then
  NOOP_ID="$(echo "${EXISTING_EXEC_JSON}" | jq -r --arg k "${NOOP_EXEC_KEY}" '.[] | select(.key==$k) | .id')"
  echo "[i] Found existing executor id=${NOOP_ID}"
else
  TMP_EXEC_JSON="$(mktemp)"
  cat > "${TMP_EXEC_JSON}" <<'JSON'
{
  "name": "NoOp Executor",
  "key": "noop-executor",
  "description": "Safe NoOp executor used for testing: logs and returns success (no external side-effects).",
  "type": "noop",
  "enabled": true,
  "configuration": {
    "behaviour": "always_succeed",
    "log_on_execute": true
  }
}
JSON
  echo "[i] Creating executor..."
  RESP="$(api_post "${OPENBAS_HOST}/api/executors" "${TMP_EXEC_JSON}" || true)"
  rm -f "${TMP_EXEC_JSON}"
  if echo "${RESP}" | jq -e '.id' >/dev/null 2>&1; then
    NOOP_ID="$(echo "${RESP}" | jq -r '.id')"
    echo "[ok] Created executor id=${NOOP_ID}"
  else
    echo "WARN: Could not create executor; response:"
    echo "${RESP}"
    echo "Attempting to find executor via list..."
    NOOP_ID="$(api_get "${OPENBAS_HOST}/api/executors" | jq -r --arg k "${NOOP_EXEC_KEY}" '.[] | select(.key==$k) | .id' 2>/dev/null || true)"
    if [[ -n "$NOOP_ID" ]]; then
      echo "[i] Found executor id=${NOOP_ID}"
    else
      echo "ERROR: executor not found and creation failed. Inspect OpenBAS API endpoints."
      exit 1
    fi
  fi
fi

# -----------------------
# 2) Create NoOp injectors
# -----------------------
echo
echo "==> 2) Creating NoOp injectors (idempotent) using executor id=${NOOP_ID}"

create_injector_if_missing() {
  local key="$1"; local name="$2"; local body="$3"
  local found
  found="$(api_get "${OPENBAS_HOST}/api/injectors" 2>/dev/null || true)"
  if echo "${found}" | jq -e --arg k "$key" '.[] | select(.key == $k)' >/dev/null 2>&1; then
    echo "[i] Injector ${key} already exists"
    return 0
  fi
  TMP="$(mktemp)"
  cat > "$TMP" <<JSON
$body
JSON
  echo "[i] Creating injector ${key}..."
  RESP="$(api_post "${OPENBAS_HOST}/api/injectors" "${TMP}" || true)"
  rm -f "$TMP"
  if echo "${RESP}" | jq -e '.id' >/dev/null 2>&1; then
    echo "[ok] Injector ${key} created (id=$(echo "${RESP}" | jq -r '.id'))"
  else
    echo "WARN: create injector response:"
    echo "${RESP}"
  fi
}

# Injector: noop.log
create_injector_if_missing "noop.log" "NoOp - Log Only" "$(cat <<JSON
{
  "name": "NoOp - Log Only",
  "key": "noop.log",
  "description": "A no-op injector that only logs an action and returns success.",
  "platforms": ["generic"],
  "killChainPhase": ["Unknown"],
  "executorId": "${NOOP_ID}",
  "parameters": [
    { "name": "message", "type": "string", "description": "Message to log", "defaultValue": "NoOp injection executed" }
  ],
  "enabled": true
}
JSON
)"

# Injector: noop.create_file
create_injector_if_missing "noop.create_file" "NoOp - Create File (simulated)" "$(cat <<JSON
{
  "name": "NoOp - Create File (simulated)",
  "key": "noop.create_file",
  "description": "Simulated file create injector (NoOp) — will not touch disk, only logs.",
  "platforms": ["windows", "linux"],
  "killChainPhase": ["Execution"],
  "executorId": "${NOOP_ID}",
  "parameters": [
    { "name": "path", "type": "string", "description": "Path that would be created", "defaultValue": "C:\\\\temp\\\\example.txt" }
  ],
  "enabled": true
}
JSON
)"

# Injector: noop.send_mail
create_injector_if_missing "noop.send_mail" "NoOp - Send Mail (simulated)" "$(cat <<JSON
{
  "name": "NoOp - Send Mail (simulated)",
  "key": "noop.send_mail",
  "description": "Simulated email injector (NoOp) — logs an event as if the mail were sent.",
  "platforms": ["generic"],
  "killChainPhase": ["Impact"],
  "executorId": "${NOOP_ID}",
  "parameters": [
    { "name": "to", "type": "string", "description": "Recipient address", "defaultValue": "victim@example.local" },
    { "name": "subject", "type": "string", "description": "Subject", "defaultValue": "Test simulated email" }
  ],
  "enabled": true
}
JSON
)"

# -----------------------
# 3) Create scenario
# -----------------------
echo
echo "==> 3) Creating scenario (idempotent)"

SCENARIO_NAME="Simulated Ransomware Playbook - NoOp"
SCENARIO_JSON="$(api_get "${OPENBAS_HOST}/api/scenarios" || true)"
SCENARIO_ID=""
if echo "${SCENARIO_JSON}" | jq -e --arg name "$SCENARIO_NAME" '.[] | select(.name == $name) | .id' >/dev/null 2>&1; then
  SCENARIO_ID="$(echo "${SCENARIO_JSON}" | jq -r --arg name "$SCENARIO_NAME" '.[] | select(.name == $name) | .id')"
  echo "[i] Found existing scenario id=${SCENARIO_ID}"
else
  TMP="$(mktemp)"
  cat > "${TMP}" <<JSON
{
  "name": "${SCENARIO_NAME}",
  "description": "Simulated scenario exercising Execution -> Persistence -> C2 -> Impact phases using NoOp executor.",
  "tags": ["exercise","mitre","simulated"],
  "attack_patterns": ["T1059","T1112","T1071","T1486"],
  "author": "install_noop_content.sh",
  "visibility": "private"
}
JSON
  echo "[i] Creating scenario..."
  RESP="$(api_post "${OPENBAS_HOST}/api/scenarios" "${TMP}" || true)"
  rm -f "${TMP}"
  if echo "${RESP}" | jq -e '.id' >/dev/null 2>&1; then
    SCENARIO_ID="$(echo "${RESP}" | jq -r '.id')"
    echo "[ok] Created scenario id=${SCENARIO_ID}"
  else
    echo "WARN: Could not create scenario; response:"
    echo "${RESP}"
    # Try to find by name anyway
    SCENARIO_ID="$(api_get "${OPENBAS_HOST}/api/scenarios" | jq -r --arg name "$SCENARIO_NAME" '.[] | select(.name==$name) | .id' 2>/dev/null || true)"
    if [[ -n "$SCENARIO_ID" ]]; then
      echo "[i] Found scenario id=${SCENARIO_ID}"
    else
      echo "ERROR: scenario creation failed and not found. Exiting."
      exit 1
    fi
  fi
fi

# -----------------------
# 4) Create a player (target)
# -----------------------
echo
echo "==> 4) Creating player (target) for scenario"

# Some OpenBAS versions use /api/scenarios/{id}/players, others use /api/players
PLAYER_ID=""
# Try to find existing player in scenario
LIST_PLAYERS="$(api_get "${OPENBAS_HOST}/api/players" || true)"
if echo "${LIST_PLAYERS}" | jq -e --arg name "${PLAYER_HOSTNAME}" '.[] | select(.name == $name)' >/dev/null 2>&1; then
  PLAYER_ID="$(echo "${LIST_PLAYERS}" | jq -r --arg name "${PLAYER_HOSTNAME}" '.[] | select(.name==$name) | .id')"
  echo "[i] Found existing player id=${PLAYER_ID}"
else
  TMP="$(mktemp)"
  cat > "${TMP}" <<JSON
{
  "name": "${PLAYER_HOSTNAME}",
  "type": "host",
  "platforms": ["windows"],
  "meta": { "ip": "${PLAYER_IP}", "hostname": "${PLAYER_HOSTNAME}" }
}
JSON
  # Try posting to /api/players
  echo "[i] Creating player..."
  RESP="$(api_post "${OPENBAS_HOST}/api/players" "${TMP}" || true)"
  rm -f "${TMP}"
  if echo "${RESP}" | jq -e '.id' >/dev/null 2>&1; then
    PLAYER_ID="$(echo "${RESP}" | jq -r '.id')"
    echo "[ok] Created player id=${PLAYER_ID}"
  else
    echo "WARN: players create returned:"
    echo "${RESP}"
    # fallback: try adding via scenario endpoint
    echo "[i] Trying scenario players endpoint..."
    TMP2="$(mktemp)"
    cat > "${TMP2}" <<JSON
{
  "players": [
    {
      "id": "player:${PLAYER_HOSTNAME}",
      "name": "${PLAYER_HOSTNAME}",
      "type": "host",
      "platforms": ["windows"],
      "meta": { "ip": "${PLAYER_IP}", "hostname": "${PLAYER_HOSTNAME}" }
    }
  ]
}
JSON
    RESP2="$(curl -sS -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" --data @"${TMP2}" "${OPENBAS_HOST}/api/scenarios/${SCENARIO_ID}/players" || true)"
    rm -f "${TMP2}"
    if echo "${RESP2}" | jq -e '.players' >/dev/null 2>&1; then
      PLAYER_ID="$(echo "${RESP2}" | jq -r '.players[0].id')"
      echo "[ok] Created/added player id=${PLAYER_ID}"
    else
      echo "ERROR: cannot create player. Response: ${RESP2}"
      exit 1
    fi
  fi
fi

# -----------------------
# 5) Create scenario steps (injects)
# -----------------------
echo
echo "==> 5) Creating scenario steps (injects) using NoOp injectors"

# helper to find injector id by key
get_injector_id() {
  local key="$1"
  api_get "${OPENBAS_HOST}/api/injectors" | jq -r --arg k "$key" '.[] | select(.key==$k) | .id' 2>/dev/null || true
}

INJ_LOG_ID="$(get_injector_id "noop.log")"
INJ_FILE_ID="$(get_injector_id "noop.create_file")"
INJ_MAIL_ID="$(get_injector_id "noop.send_mail")"

if [[ -z "$INJ_LOG_ID" || -z "$INJ_FILE_ID" || -z "$INJ_MAIL_ID" ]]; then
  echo "ERROR: expected injectors not found. List of injectors:"
  api_get "${OPENBAS_HOST}/api/injectors" | jq . || true
  exit 1
fi

# convenience: create a step if not present (by name)
create_step_if_missing() {
  local step_name="$1"
  local payload="$2"
  # Try to see existing steps for the scenario
  EXIST_STEPS="$(api_get "${OPENBAS_HOST}/api/scenarios/${SCENARIO_ID}/steps" || true)"
  if echo "${EXIST_STEPS}" | jq -e --arg n "$step_name" '.[] | select(.name==$n)' >/dev/null 2>&1; then
    echo "[i] Step '${step_name}' already exists for scenario"
    return 0
  fi
  TMP="$(mktemp)"
  cat > "${TMP}" <<JSON
$payload
JSON
  echo "[i] Creating step '${step_name}'..."
  RESP="$(api_post "${OPENBAS_HOST}/api/scenarios/${SCENARIO_ID}/steps" "${TMP}" || true)"
  rm -f "${TMP}"
  if echo "${RESP}" | jq -e '.id' >/dev/null 2>&1; then
    echo "[ok] Created step '${step_name}' id=$(echo "${RESP}" | jq -r '.id')"
  else
    echo "WARN: create step response:"
    echo "${RESP}"
  fi
}

# Execution step
create_step_if_missing "Execution: Simulated PowerShell" "$(cat <<JSON
{
  "name": "Execution: Simulated PowerShell",
  "killChainPhase": "Execution",
  "attackPatterns": ["T1059"],
  "injectorId": "${INJ_LOG_ID}",
  "injectorKey": "noop.log",
  "executorId": "${NOOP_ID}",
  "parameters": { "message": "Simulated powershell execution: powershell -NoProfile -File C:\\\\temp\\\\run.ps1" },
  "targets": ["${PLAYER_ID}"],
  "order": 10
}
JSON
)"

# Persistence step
create_step_if_missing "Persistence: Simulated scheduled task" "$(cat <<JSON
{
  "name": "Persistence: Simulated scheduled task",
  "killChainPhase": "Persistence",
  "attackPatterns": ["T1053"],
  "injectorId": "${INJ_FILE_ID}",
  "injectorKey": "noop.create_file",
  "executorId": "${NOOP_ID}",
  "parameters": { "path": "C:\\\\Windows\\\\System32\\\\Tasks\\\\UpdaterTask" },
  "targets": ["${PLAYER_ID}"],
  "order": 20
}
JSON
)"

# C2 step
create_step_if_missing "C2: Simulated HTTPS beacon" "$(cat <<JSON
{
  "name": "C2: Simulated HTTPS beacon",
  "killChainPhase": "Command-and-Control",
  "attackPatterns": ["T1071"],
  "injectorId": "${INJ_LOG_ID}",
  "injectorKey": "noop.log",
  "executorId": "${NOOP_ID}",
  "parameters": { "message": "Simulated HTTPS beacon to https://example-cc.server/api/checkin" },
  "targets": ["${PLAYER_ID}"],
  "order": 30
}
JSON
)"

# Impact step
create_step_if_missing "Impact: Simulated encrypted marker" "$(cat <<JSON
{
  "name": "Impact: Simulated encrypted marker",
  "killChainPhase": "Impact",
  "attackPatterns": ["T1486"],
  "injectorId": "${INJ_FILE_ID}",
  "injectorKey": "noop.create_file",
  "executorId": "${NOOP_ID}",
  "parameters": { "path": "C:\\\\Users\\\\Public\\\\encrypted_marker.txt", "content": "SIMULATED_ENCRYPTED" },
  "targets": ["${PLAYER_ID}"],
  "order": 40
}
JSON
)"

# -----------------------
# 6) Optionally trigger a test inject run
# -----------------------
echo
if [[ "${NO_RUN}" = true ]]; then
  echo "[i] --no-run specified, skipping run trigger"
else
  echo "==> 6) Triggering a test inject run (safe, NoOp only)"
  # Build a run request - many OpenBAS versions accept POST /api/injects
  RUN_REQ="$(mktemp)"
  cat > "${RUN_REQ}" <<JSON
{
  "scenarioId": "${SCENARIO_ID}",
  "name": "Smoke test run - NoOp",
  "notes": "Automated test run created by install_noop_content.sh",
  "targets": ["${PLAYER_ID}"],
  "scheduledAt": null,
  "runNow": true
}
JSON

  RESP_RUN="$(curl -sS -X POST -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" --data @"${RUN_REQ}" "${OPENBAS_HOST}/api/injects" || true)"
  rm -f "${RUN_REQ}"
  if echo "${RESP_RUN}" | jq -e '.id' >/dev/null 2>&1; then
    echo "[ok] Started run id=$(echo "${RESP_RUN}" | jq -r '.id')"
  else
    echo "WARN: run trigger returned:"
    echo "${RESP_RUN}"
    echo "[i] Trying fallback: POST /api/scenarios/{id}/run"
    RESP_FB="$(curl -sS -X POST -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" --data '{"options":{"runNow":true}}' "${OPENBAS_HOST}/api/scenarios/${SCENARIO_ID}/run" || true)"
    echo "Fallback response: ${RESP_FB}"
  fi
fi

# -----------------------
# 7) Optionally inject synthetic telemetry into Elasticsearch
# -----------------------
if [[ "${NO_TELEMETRY}" = true ]]; then
  echo "[i] --no-telemetry specified, skipping telemetry indexing"
else
  echo
  echo "==> 7) Indexing synthetic telemetry into Elasticsearch (${ES_URL})"
  if curl -sS "${ES_URL}" >/dev/null 2>&1; then
    BULK="$(mktemp)"
    NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat > "${BULK}" <<JSON
{"index":{"_index":"${ES_INDEX}","_id":"proc1"}}
{"@timestamp":"${NOW}","event":{"action":"process_start"},"process":{"name":"powershell.exe","pid":1234,"command_line":"powershell -NoProfile -ExecutionPolicy Bypass -File C:\\\\temp\\\\run.ps1"},"host":{"hostname":"${PLAYER_HOSTNAME}","ip":"${PLAYER_IP}"},"tags":["simulated","openbas"]}
{"index":{"_index":"${ES_INDEX}","_id":"net1"}}
{"@timestamp":"${NOW}","event":{"action":"network_flow"},"network":{"transport":"https","destination":"example-cc.server","port":443},"host":{"hostname":"${PLAYER_HOSTNAME}","ip":"${PLAYER_IP}"},"tags":["simulated","openbas"]}
{"index":{"_index":"${ES_INDEX}","_id":"file1"}}
{"@timestamp":"${NOW}","event":{"action":"file_create"},"file":{"path":"C:\\\\Users\\\\Public\\\\encrypted_marker.txt","sha256":"deadbeef"},"host":{"hostname":"${PLAYER_HOSTNAME}","ip":"${PLAYER_IP}"},"tags":["simulated","openbas"]}
JSON
    # bulk index
    if curl -sS -H "Content-Type: application/x-ndjson" --data-binary @"${BULK}" "${ES_URL}/_bulk" | jq -r '.' >/dev/null 2>&1; then
      echo "[ok] Telemetry bulk indexed into index: ${ES_INDEX}"
    else
      echo "WARN: bulk index failed - response:"
      curl -sS -H "Content-Type: application/x-ndjson" --data-binary @"${BULK}" "${ES_URL}/_bulk" || true
    fi
    rm -f "${BULK}"
  else
    echo "WARN: Could not reach Elasticsearch at ${ES_URL}; skipping telemetry."
  fi
fi

echo
echo "All done. Summary:"
echo "  OpenBAS host   : ${OPENBAS_HOST}"
echo "  Scenario id    : ${SCENARIO_ID}"
echo "  Player id      : ${PLAYER_ID}"
echo "  NoOp executor  : ${NOOP_ID}"
echo
echo "In the OpenBAS UI: Scenarios → '${SCENARIO_NAME}' → view steps and run history."
echo "If run triggered, watch scenario timeline and logs in the UI."