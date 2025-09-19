#!/usr/bin/env bash
set -euo pipefail

# install_openbas_simulation.sh
# - Creates NoOp executor + injectors (safe)
# - Detects agent executor (winrm/agent) and uses it for Execution steps if present
# - Creates scenario, player, steps and triggers a safe run (whoami) on agent or NoOp
# - Optionally bulk indexes synthetic telemetry into ES (if ES_URL reachable)
#
# Usage:
#   OPENBAS_HOST="http://127.0.0.1:4000" OPENBAS_TOKEN="..." ES_URL="http://elasticsearch:9200" ./install_openbas_simulation.sh
#
# Options (CLI):
#   --no-run         skip triggering a test run
#   --no-telemetry   skip indexing synthetic telemetry
#
# Required env:
#   OPENBAS_HOST  (default: http://127.0.0.1:4000)
#   OPENBAS_TOKEN (required)
#
: "${OPENBAS_HOST:=${OPENBAS_HOST:-http://127.0.0.1:4000}}"
: "${OPENBAS_TOKEN:=${OPENBAS_TOKEN:-}}"
ES_URL="${ES_URL:-http://elasticsearch:9200}"
ES_INDEX="${ES_INDEX:-openbas-simulated}"
PLAYER_HOSTNAME="${PLAYER_HOSTNAME:-host-win10-1}"
PLAYER_IP="${PLAYER_IP:-10.0.0.21}"

if [[ -z "$OPENBAS_TOKEN" ]]; then
  echo "ERROR: OPENBAS_TOKEN must be set (export OPENBAS_TOKEN=\"...\")"
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

for cmd in curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: $cmd required but not installed"
    exit 1
  fi
done

# Helpers
api_get() {
  local url="$1"
  curl -sS -H "Authorization: Bearer ${OPENBAS_TOKEN}" "${url}"
}
api_post_file() {
  local url="$1" ; local file="$2"
  curl -sS -X POST -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" --data-binary @"${file}" "${url}"
}
api_post_json() {
  local url="$1" ; local json="$2"
  curl -sS -X POST -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" --data "$json" "${url}"
}

echo
echo "OpenBAS host: ${OPENBAS_HOST}"
echo "Using token: $(echo ${OPENBAS_TOKEN} | cut -c1-6)...."
echo

# Basic health hint
if ! curl -sf "${OPENBAS_HOST}/actuator/health" >/dev/null 2>&1; then
  echo "WARNING: Could not reach ${OPENBAS_HOST}/actuator/health - continuing anyway. Check connectivity if operations fail."
fi

# 1) Ensure NoOp executor exists (safe default)
NOOP_KEY="noop-executor"
echo "==> Ensure NoOp executor exists..."
EXEC_LIST="$(api_get "${OPENBAS_HOST}/api/executors" || true)"
NOOP_ID="$(echo "${EXEC_LIST}" | jq -r --arg k "$NOOP_KEY" '.[] | select(.key==$k) | .id' 2>/dev/null || true)"
if [[ -n "$NOOP_ID" && "$NOOP_ID" != "null" ]]; then
  echo "[i] Found existing NoOp executor id=${NOOP_ID}"
else
  tmpf="$(mktemp)"
  cat > "${tmpf}" <<'JSON'
{
  "name":"NoOp Executor",
  "key":"noop-executor",
  "description":"Safe NoOp executor used for testing: logs and returns success (no external side-effects).",
  "type":"noop",
  "enabled":true,
  "configuration": {"behaviour":"always_succeed","log_on_execute":true}
}
JSON
  resp="$(api_post_file "${OPENBAS_HOST}/api/executors" "${tmpf}" || true)"
  rm -f "${tmpf}"
  NOOP_ID="$(echo "${resp}" | jq -r '.id // empty' || true)"
  if [[ -n "$NOOP_ID" ]]; then
    echo "[ok] Created NoOp executor id=${NOOP_ID}"
  else
    echo "WARN: Could not create NoOp executor; trying to find via list..."
    NOOP_ID="$(api_get "${OPENBAS_HOST}/api/executors" | jq -r --arg k "$NOOP_KEY" '.[] | select(.key==$k) | .id' 2>/dev/null || true)"
    if [[ -n "$NOOP_ID" ]]; then
      echo "[i] Found NoOp executor after all id=${NOOP_ID}"
    else
      echo "ERROR: NoOp executor creation failed; aborting."
      exit 1
    fi
  fi
fi

# 2) Auto-detect agent executor (prefer winrm/agent/caldera)
echo
echo "==> Detecting agent executor (winrm/agent/caldera preferred)..."
AGENT_EXEC_ID=""
AGENT_CANDIDATE="$(echo "${EXEC_LIST}" | jq -c '.[]' 2>/dev/null || true)"
if [[ -z "${AGENT_CANDIDATE}" || "${AGENT_CANDIDATE}" == "null" ]]; then
  # refresh list
  EXEC_LIST="$(api_get "${OPENBAS_HOST}/api/executors" || true)"
fi

# Search for probable agent types
AGENT_EXEC_ID="$(echo "${EXEC_LIST}" | jq -r 'map(select((.type|ascii_downcase|tostring|contains("winrm") or contains("agent") or contains("caldera") ) or (.key|ascii_downcase|tostring|contains("winrm") or contains("agent") or contains("caldera")) or (.name|ascii_downcase|tostring|contains("winrm") or contains("agent") or contains("caldera")))) | .[0].id // empty')"

if [[ -n "$AGENT_EXEC_ID" ]]; then
  echo "[i] Detected agent executor id=${AGENT_EXEC_ID}"
  USE_AGENT=true
else
  echo "[i] No agent executor detected — will use NoOp for execution steps"
  USE_AGENT=false
fi

# 3) Create base NoOp injectors if missing
echo
echo "==> Ensure base NoOp injectors exist..."
create_injector() {
  local key="$1" ; local body="$2"
  if api_get "${OPENBAS_HOST}/api/injectors" | jq -e --arg k "$key" '.[] | select(.key==$k)' >/dev/null 2>&1; then
    echo "[i] Injector $key already exists"
    return 0
  fi
  tmp="$(mktemp)"
  echo "$body" > "$tmp"
  resp="$(api_post_file "${OPENBAS_HOST}/api/injectors" "${tmp}" || true)"
  rm -f "$tmp"
  if echo "${resp}" | jq -e '.id' >/dev/null 2>&1; then
    echo "[ok] Created injector $key (id=$(echo "${resp}" | jq -r '.id'))"
  else
    echo "WARN: create injector $key response:"
    echo "${resp}"
  fi
}

create_injector "noop.log" '{
  "name":"NoOp - Log Only",
  "key":"noop.log",
  "description":"A no-op injector that only logs an action and returns success.",
  "platforms":["generic"],
  "killChainPhase":["Unknown"],
  "executorId":"'"${NOOP_ID}"'",
  "parameters":[{"name":"message","type":"string","description":"Message to log","defaultValue":"NoOp injection executed"}],
  "enabled":true
}'

create_injector "noop.create_file" '{
  "name":"NoOp - Create File (simulated)",
  "key":"noop.create_file",
  "description":"Simulated file create injector (NoOp) — will not touch disk, only logs.",
  "platforms":["windows","linux"],
  "killChainPhase":["Execution"],
  "executorId":"'"${NOOP_ID}"'",
  "parameters":[{"name":"path","type":"string","description":"Path that would be created","defaultValue":"C:\\\\temp\\\\example.txt"}],
  "enabled":true
}'

create_injector "noop.send_mail" '{
  "name":"NoOp - Send Mail (simulated)",
  "key":"noop.send_mail",
  "description":"Simulated email injector (NoOp) — logs an event as if the mail were sent.",
  "platforms":["generic"],
  "killChainPhase":["Impact"],
  "executorId":"'"${NOOP_ID}"'",
  "parameters":[{"name":"to","type":"string","description":"Recipient address","defaultValue":"victim@example.local"},{"name":"subject","type":"string","description":"Subject","defaultValue":"Test simulated email"}],
  "enabled":true
}'

# 4) If agent executor present, create an agent-run injector that uses it
AGENT_INJECTOR_KEY="agent.exec.command"
AGENT_INJECTOR_ID=""
if [[ "$USE_AGENT" == true ]]; then
  echo
  echo "==> Create agent-run injector (uses detected agent executor id=${AGENT_EXEC_ID})"
  # If injector exists, get id
  AGENT_INJECTOR_ID="$(api_get "${OPENBAS_HOST}/api/injectors" | jq -r --arg k "$AGENT_INJECTOR_KEY" '.[] | select(.key==$k) | .id' 2>/dev/null || true)"
  if [[ -n "$AGENT_INJECTOR_ID" ]]; then
    echo "[i] Found existing agent injector id=${AGENT_INJECTOR_ID}"
  else
    tmpf="$(mktemp)"
    cat > "${tmpf}" <<JSON
{
  "name": "Agent - Run Command",
  "key": "${AGENT_INJECTOR_KEY}",
  "description": "Run a shell/PowerShell command on target via agent executor",
  "platforms": ["windows"],
  "killChainPhase": ["Execution"],
  "executorId": "${AGENT_EXEC_ID}",
  "parameters": [
    { "name": "command", "type": "string", "description": "Command to execute", "defaultValue": "whoami" }
  ],
  "enabled": true
}
JSON
    resp="$(api_post_file "${OPENBAS_HOST}/api/injectors" "${tmpf}" || true)"
    rm -f "${tmpf}"
    AGENT_INJECTOR_ID="$(echo "${resp}" | jq -r '.id // empty' || true)"
    if [[ -n "$AGENT_INJECTOR_ID" ]]; then
      echo "[ok] Created agent injector id=${AGENT_INJECTOR_ID}"
    else
      echo "WARN: Could not create agent injector; response:"
      echo "${resp}"
      echo "[i] Will attempt to continue; you may need to create agent injector manually or check API endpoints."
      USE_AGENT=false
    fi
  fi
fi

# 5) Create scenario (idempotent)
echo
echo "==> Create scenario if missing"
SCENARIO_NAME="Simulated Ransomware Playbook - Auto"
SCENARIO_ID="$(api_get "${OPENBAS_HOST}/api/scenarios" | jq -r --arg n "${SCENARIO_NAME}" '.[] | select(.name==$n) | .id' 2>/dev/null || true)"
if [[ -n "$SCENARIO_ID" ]]; then
  echo "[i] Found scenario id=${SCENARIO_ID}"
else
  tmpf="$(mktemp)"
  cat > "${tmpf}" <<JSON
{
  "name":"${SCENARIO_NAME}",
  "description":"Simulated scenario exercising Execution -> Persistence -> C2 -> Impact phases.",
  "tags":["exercise","simulated"],
  "attack_patterns":["T1059","T1112","T1071","T1486"],
  "author":"install_openbas_simulation.sh",
  "visibility":"private"
}
JSON
  resp="$(api_post_file "${OPENBAS_HOST}/api/scenarios" "${tmpf}" || true)"
  rm -f "${tmpf}"
  SCENARIO_ID="$(echo "${resp}" | jq -r '.id // empty' || true)"
  if [[ -n "$SCENARIO_ID" ]]; then
    echo "[ok] Created scenario id=${SCENARIO_ID}"
  else
    echo "WARN: could not create scenario; response:"
    echo "${resp}"
    echo "[i] Attempt to find scenario in list..."
    SCENARIO_ID="$(api_get "${OPENBAS_HOST}/api/scenarios" | jq -r --arg n "${SCENARIO_NAME}" '.[] | select(.name==$n) | .id' 2>/dev/null || true)"
    if [[ -n "$SCENARIO_ID" ]]; then
      echo "[i] Found scenario id=${SCENARIO_ID}"
    else
      echo "ERROR: scenario creation failed; aborting."
      exit 1
    fi
  fi
fi

# 6) Create/Get player (target). If you have a real agent, prefer matching hostname
echo
echo "==> Ensure player exists (target)"
PLAYER_ID="$(api_get "${OPENBAS_HOST}/api/players" | jq -r --arg hn "${PLAYER_HOSTNAME}" '.[] | select(.name==$hn) | .id' 2>/dev/null || true)"
if [[ -n "$PLAYER_ID" ]]; then
  echo "[i] Found player id=${PLAYER_ID} (name=${PLAYER_HOSTNAME})"
else
  tmpf="$(mktemp)"
  cat > "${tmpf}" <<JSON
{
  "name": "${PLAYER_HOSTNAME}",
  "type": "host",
  "platforms": ["windows"],
  "meta": { "ip": "${PLAYER_IP}", "hostname": "${PLAYER_HOSTNAME}" }
}
JSON
  resp="$(api_post_file "${OPENBAS_HOST}/api/players" "${tmpf}" || true)"
  rm -f "${tmpf}"
  PLAYER_ID="$(echo "${resp}" | jq -r '.id // empty' || true)"
  if [[ -n "$PLAYER_ID" ]]; then
    echo "[ok] Created player id=${PLAYER_ID}"
  else
    echo "WARN: could not create player - attempting to add via scenario players endpoint..."
    tmpf2="$(mktemp)"
    cat > "${tmpf2}" <<JSON
{ "players": [ { "id": "player:${PLAYER_HOSTNAME}", "name": "${PLAYER_HOSTNAME}", "type": "host", "platforms": ["windows"], "meta": { "ip": "${PLAYER_IP}", "hostname": "${PLAYER_HOSTNAME}" } } ] }
JSON
    resp2="$(curl -sS -X POST -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" --data @"${tmpf2}" "${OPENBAS_HOST}/api/scenarios/${SCENARIO_ID}/players" || true)"
    rm -f "${tmpf2}"
    PLAYER_ID="$(echo "${resp2}" | jq -r '.players[0].id // empty' || true)"
    if [[ -n "$PLAYER_ID" ]]; then
      echo "[ok] Created/added player id=${PLAYER_ID}"
    else
      echo "ERROR: failed to create player; response:"
      echo "${resp2}"
      exit 1
    fi
  fi
fi

# 7) Find injector ids to use in steps
INJ_LOG_ID="$(api_get "${OPENBAS_HOST}/api/injectors" | jq -r '.[] | select(.key=="noop.log") | .id' 2>/dev/null || true)"
INJ_FILE_ID="$(api_get "${OPENBAS_HOST}/api/injectors" | jq -r '.[] | select(.key=="noop.create_file") | .id' 2>/dev/null || true)"
INJ_MAIL_ID="$(api_get "${OPENBAS_HOST}/api/injectors" | jq -r '.[] | select(.key=="noop.send_mail") | .id' 2>/dev/null || true)"
INJ_AGENT_ID="$(api_get "${OPENBAS_HOST}/api/injectors" | jq -r --arg k "${AGENT_INJECTOR_KEY:-}" '.[] | select(.key==$k) | .id' 2>/dev/null || true)"

# fallback ensure we have these values
: "${INJ_LOG_ID:=${INJ_LOG_ID:-}}"
: "${INJ_FILE_ID:=${INJ_FILE_ID:-}}"
: "${INJ_MAIL_ID:=${INJ_MAIL_ID:-}}"

if [[ -z "$INJ_LOG_ID" || -z "$INJ_FILE_ID" ]]; then
  echo "ERROR: required injectors missing. List injectors for debug:"
  api_get "${OPENBAS_HOST}/api/injectors" | jq . || true
  exit 1
fi

# 8) Create scenario steps (idempotent). Execution step uses agent injector if present.
echo
echo "==> Creating scenario steps (idempotent)"
create_step() {
  local payload="$1" ; local name="$2"
  # check existing by name
  EXIST="$(curl -sS -H "Authorization: Bearer ${OPENBAS_TOKEN}" "${OPENBAS_HOST}/api/scenarios/${SCENARIO_ID}/steps" || true)"
  if echo "${EXIST}" | jq -e --arg n "$name" '.[] | select(.name==$n)' >/dev/null 2>&1; then
    echo "[i] Step '$name' already exists"
    return 0
  fi
  tmp="$(mktemp)"
  echo "$payload" > "$tmp"
  resp="$(api_post_file "${OPENBAS_HOST}/api/scenarios/${SCENARIO_ID}/steps" "${tmp}" || true)"
  rm -f "${tmp}"
  if echo "${resp}" | jq -e '.id' >/dev/null 2>&1; then
    echo "[ok] Created step '$name' id=$(echo "${resp}" | jq -r '.id')"
  else
    echo "WARN: create step response:"
    echo "${resp}"
  fi
}

# Execution step (prefer agent)
if [[ "$USE_AGENT" == true && -n "$INJ_AGENT_ID" ]]; then
  EXEC_INJECTOR_REF_FIELD="injectorId"
  EXEC_INJECTOR_REF_VALUE="${INJ_AGENT_ID}"
  EXEC_INJECTOR_KEY_FIELD="injectorKey"
  EXEC_INJECTOR_KEY_VALUE="${AGENT_INJECTOR_KEY}"
else
  EXEC_INJECTOR_REF_FIELD="injectorId"
  EXEC_INJECTOR_REF_VALUE="${INJ_LOG_ID}"
  EXEC_INJECTOR_KEY_FIELD="injectorKey"
  EXEC_INJECTOR_KEY_VALUE="noop.log"
fi

create_step "$(cat <<JSON
{
  "name":"Execution: Run benign command",
  "killChainPhase":"Execution",
  "attackPatterns":["T1059"],
  "${EXEC_INJECTOR_REF_FIELD}":"${EXEC_INJECTOR_REF_VALUE}",
  "${EXEC_INJECTOR_KEY_FIELD}":"${EXEC_INJECTOR_KEY_VALUE}",
  "executorId":"${USE_AGENT:+${AGENT_EXEC_ID}${USE_AGENT:+} }${USE_AGENT:+}${NOOP_ID:+${NOOP_ID}}",
  "parameters": { "command": "whoami" },
  "targets": ["${PLAYER_ID}"],
  "order": 10
}
JSON
"Execution: Run benign command") || true

# Persistence
create_step "$(cat <<JSON
{
  "name":"Persistence: Simulated scheduled task",
  "killChainPhase":"Persistence",
  "attackPatterns":["T1053"],
  "injectorId":"${INJ_FILE_ID}",
  "injectorKey":"noop.create_file",
  "executorId":"${NOOP_ID}",
  "parameters": { "path": "C:\\\\Windows\\\\System32\\\\Tasks\\\\UpdaterTask" },
  "targets": ["${PLAYER_ID}"],
  "order": 20
}
JSON
"Persistence: Simulated scheduled task") || true

# C2
create_step "$(cat <<JSON
{
  "name":"C2: Simulated HTTPS beacon",
  "killChainPhase":"Command-and-Control",
  "attackPatterns":["T1071"],
  "injectorId":"${INJ_LOG_ID}",
  "injectorKey":"noop.log",
  "executorId":"${NOOP_ID}",
  "parameters": { "message": "Simulated HTTPS beacon to https://example-cc.server/api/checkin" },
  "targets": ["${PLAYER_ID}"],
  "order": 30
}
JSON
"C2: Simulated HTTPS beacon") || true

# Impact
create_step "$(cat <<JSON
{
  "name":"Impact: Simulated encrypted marker",
  "killChainPhase":"Impact",
  "attackPatterns":["T1486"],
  "injectorId":"${INJ_FILE_ID}",
  "injectorKey":"noop.create_file",
  "executorId":"${NOOP_ID}",
  "parameters": { "path": "C:\\\\Users\\\\Public\\\\encrypted_marker.txt", "content": "SIMULATED_ENCRYPTED" },
  "targets": ["${PLAYER_ID}"],
  "order": 40
}
JSON
"Impact: Simulated encrypted marker") || true

# 9) Trigger a run (unless disabled)
echo
if [[ "${NO_RUN}" == "true" ]]; then
  echo "[i] --no-run given, skipping run trigger"
else
  echo "==> Triggering a test run for scenario ${SCENARIO_ID} targeting player ${PLAYER_ID}..."
  # Attempt standard endpoint POST /api/injects
  run_payload="$(mktemp)"
  cat > "${run_payload}" <<JSON
{"scenarioId":"${SCENARIO_ID}","name":"Smoke test run - auto","notes":"Automated run from install_openbas_simulation.sh","targets":["${PLAYER_ID}"],"runNow":true}
JSON
  resp_run="$(curl -sS -X POST -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" --data @"${run_payload}" "${OPENBAS_HOST}/api/injects" || true)"
  rm -f "${run_payload}"
  if echo "${resp_run}" | jq -e '.id' >/dev/null 2>&1; then
    echo "[ok] Run started id=$(echo "${resp_run}" | jq -r '.id')"
  else
    echo "WARN: /api/injects did not create run. Response:"
    echo "${resp_run}"
    echo "[i] Attempting fallback POST /api/scenarios/{id}/run ..."
    resp_fb="$(curl -sS -X POST -H "Authorization: Bearer ${OPENBAS_TOKEN}" -H "Content-Type: application/json" --data '{"options":{"runNow":true}}' "${OPENBAS_HOST}/api/scenarios/${SCENARIO_ID}/run" || true)"
    echo "Fallback response: ${resp_fb}"
  fi
fi

# 10) Optionally index synthetic telemetry into Elasticsearch
echo
if [[ "${NO_TELEMETRY}" == "true" ]]; then
  echo "[i] --no-telemetry given, skipping telemetry indexing"
else
  echo "==> Attempting to index synthetic telemetry into Elasticsearch (${ES_URL})"
  if curl -sS "${ES_URL}" >/dev/null 2>&1; then
    bulkf="$(mktemp)"
    nowts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    cat > "${bulkf}" <<JSON
{"index":{"_index":"${ES_INDEX}","_id":"proc1"}}
{"@timestamp":"${nowts}","event":{"action":"process_start"},"process":{"name":"whoami.exe","pid":1234,"command_line":"whoami"},"host":{"hostname":"${PLAYER_HOSTNAME}","ip":"${PLAYER_IP}"},"tags":["simulated","openbas"]}
{"index":{"_index":"${ES_INDEX}","_id":"net1"}}
{"@timestamp":"${nowts}","event":{"action":"network_flow"},"network":{"transport":"https","destination":"example-cc.server","port":443},"host":{"hostname":"${PLAYER_HOSTNAME}","ip":"${PLAYER_IP}"},"tags":["simulated","openbas"]}
{"index":{"_index":"${ES_INDEX}","_id":"file1"}}
{"@timestamp":"${nowts}","event":{"action":"file_create"},"file":{"path":"C:\\\\Users\\\\Public\\\\encrypted_marker.txt","sha256":"deadbeef"},"host":{"hostname":"${PLAYER_HOSTNAME}","ip":"${PLAYER_IP}"},"tags":["simulated","openbas"]}
JSON
    resp_es="$(curl -sS -H "Content-Type: application/x-ndjson" --data-binary @"${bulkf}" "${ES_URL}/_bulk" || true)"
    echo "ES bulk response (truncated):"
    echo "${resp_es}" | jq -r 'if .errors==true then "errors:true" else "errors:false" end'
    rm -f "${bulkf}"
    echo "[i] If index created, view via Kibana or search ${ES_INDEX}"
  else
    echo "WARN: Elasticsearch not reachable at ${ES_URL}; skipped telemetry indexing."
  fi
fi

echo
echo "== DONE =="
echo "Scenario: ${SCENARIO_NAME} (id: ${SCENARIO_ID})"
echo "Player: ${PLAYER_HOSTNAME} (id: ${PLAYER_ID})"
if [[ "$USE_AGENT" == true ]]; then
  echo "Agent executor used: ${AGENT_EXEC_ID}"
  echo "Agent injector key: ${AGENT_INJECTOR_KEY}"
else
  echo "No agent detected; NoOp executor used for all steps (safe)"
fi
echo
echo "Open the OpenBAS UI → Scenarios → '${SCENARIO_NAME}' to inspect steps and run history."