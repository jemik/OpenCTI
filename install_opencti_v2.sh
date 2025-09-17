#!/usr/bin/env bash
set -euo pipefail

# =========================================
# Flags
#   --fresh         : wipe volumes and do a clean reinstall
#   --with-openbas  : also deploy OpenBAS stack
# =========================================

FRESH="no"
WITH_OPENBAS="no"
for arg in "$@"; do
  case "$arg" in
    --fresh) FRESH="yes" ;;
    --with-openbas) WITH_OPENBAS="yes" ;;
    *) echo "Unknown option: $arg"; exit 1 ;;
  case_esac=true
  esac
done

# ===== Versions & Ports =====
STACK_DIR="${STACK_DIR:-/opt/opencti}"
OPENCTI_VERSION="${OPENCTI_VERSION:-6.4.6}"
ELASTIC_VERSION="${ELASTIC_VERSION:-8.13.4}"
NEO4J_VERSION="${NEO4J_VERSION:-5.19.0}"
MINIO_VERSION="${MINIO_VERSION:-RELEASE.2024-06-13T22-53-53Z}"
RABBIT_VERSION="${RABBIT_VERSION:-3.13-management}"
REDIS_VERSION="${REDIS_VERSION:-7.2}"
OPENCTI_PORT="${OPENCTI_PORT:-8080}"

# OpenBAS (optional)
OPENBAS_VERSION="${OPENBAS_VERSION:-latest}"
OPENBAS_PORT="${OPENBAS_PORT:-4000}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"

# ===== Secrets (auto-generate if empty) =====
OPENCTI_ADMIN_EMAIL="${OPENCTI_ADMIN_EMAIL:-admin@local}"
OPENCTI_ADMIN_PASS="${OPENCTI_ADMIN_PASS:-}"
OPENCTI_ADMIN_TOKEN="${OPENCTI_ADMIN_TOKEN:-}"

ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
RABBITMQ_DEFAULT_USER="${RABBITMQ_DEFAULT_USER:-opencti}"
RABBITMQ_DEFAULT_PASS="${RABBITMQ_DEFAULT_PASS:-}"
NEO4J_PASSWORD="${NEO4J_PASSWORD:-}"

# OpenBAS secrets (only used with --with-openbas)
OPENBAS_ADMIN_EMAIL="${OPENBAS_ADMIN_EMAIL:-admin@local}"
OPENBAS_ADMIN_PASS="${OPENBAS_ADMIN_PASS:-}"
OPENBAS_ADMIN_TOKEN="${OPENBAS_ADMIN_TOKEN:-}"
POSTGRES_DB="${POSTGRES_DB:-openbas}"
POSTGRES_USER="${POSTGRES_USER:-openbas}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

# ===== Trend Vision One connector =====
TV1_API_ROOT="${TV1_API_ROOT:-https://api.eu.xdr.trendmicro.com}"
TV1_API_KEY="${TV1_API_KEY:-CHANGEME_TREND_V1_API_KEY}"
TV1_CONTEXTUAL_FILTER="${TV1_CONTEXTUAL_FILTER:-}"   # optional
TV1_LOCATION="${TV1_LOCATION:-No specified locations}"
TV1_INDUSTRY="${TV1_INDUSTRY:-No specified industries}"
POLL_MINUTES="${POLL_MINUTES:-60}"
SLEEP_SECONDS="${SLEEP_SECONDS:-900}"
TOP_REPORT="${TOP_REPORT:-100}"
RESPONSE_FORMAT="${RESPONSE_FORMAT:-taxiiEnvelope}"

# ================================================

maybe_install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "[*] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER" || true
    echo "[*] Docker installed."
  fi
  if ! docker compose version >/dev/null 2>&1; then
    echo "[*] Installing Docker Compose plugin..."
    if command -v apt >/dev/null 2>&1; then
      sudo apt-get update -y && sudo apt-get install -y docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
      sudo yum install -y docker-compose-plugin
    else
      echo "(!) Please install Docker Compose plugin manually."
    fi
  fi

  echo "[*] Setting vm.max_map_count=262144 for Elasticsearch..."
  sudo sysctl -w vm.max_map_count=262144 || true
  sudo grep -q '^vm.max_map_count=' /etc/sysctl.conf || echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf >/dev/null
}

randhex() { openssl rand -hex 24; }
uuidv4()  { cat /proc/sys/kernel/random/uuid; }

ensure_secrets() {
  [[ -n "$OPENCTI_ADMIN_PASS" ]]    || OPENCTI_ADMIN_PASS="$(randhex)"
  [[ -n "$OPENCTI_ADMIN_TOKEN" ]]   || OPENCTI_ADMIN_TOKEN="$(uuidv4)"
  [[ -n "$ELASTIC_PASSWORD" ]]      || ELASTIC_PASSWORD="$(randhex)"
  [[ -n "$MINIO_ROOT_PASSWORD" ]]   || MINIO_ROOT_PASSWORD="$(randhex)"
  [[ -n "$RABBITMQ_DEFAULT_PASS" ]] || RABBITMQ_DEFAULT_PASS="$(randhex)"
  [[ -n "$NEO4J_PASSWORD" ]]        || NEO4J_PASSWORD="$(randhex)"

  if [[ "$WITH_OPENBAS" == "yes" ]]; then
    [[ -n "$OPENBAS_ADMIN_PASS" ]]  || OPENBAS_ADMIN_PASS="$(randhex)"
    [[ -n "$OPENBAS_ADMIN_TOKEN" ]] || OPENBAS_ADMIN_TOKEN="$(uuidv4)"
    [[ -n "$POSTGRES_PASSWORD" ]]   || POSTGRES_PASSWORD="$(randhex)"
  fi

  # Sanity: do not allow empties (admins)
  for v in OPENCTI_ADMIN_EMAIL OPENCTI_ADMIN_PASS OPENCTI_ADMIN_TOKEN; do
    if [[ -z "${!v}" ]]; then echo "ERROR: $v must not be empty"; exit 1; fi
  done
  if [[ "$WITH_OPENBAS" == "yes" ]]; then
    for v in OPENBAS_ADMIN_EMAIL OPENBAS_ADMIN_PASS OPENBAS_ADMIN_TOKEN POSTGRES_PASSWORD; do
      if [[ -z "${!v}" ]]; then echo "ERROR: $v must not be empty"; exit 1; fi
    done
  fi
}

wipe_stack_if_requested() {
  if [[ "$FRESH" != "yes" ]]; then
    echo "[i] --fresh not supplied: preserving existing volumes."
    return
  fi
  echo "[*] --fresh supplied: stopping stack and wiping volumes..."
  if [[ -f "$STACK_DIR/docker-compose.yml" ]]; then
    (cd "$STACK_DIR" && docker compose down -v || true)
  fi
  for v in esdata s3data rabbitmqdata redisdata neo4jdata neo4jlogs openctidata pgdata; do
    docker volume rm "${v}" 2>/dev/null || true
  done
}

write_files() {
  sudo mkdir -p "$STACK_DIR/connectors/trend-v1-opencti"
  sudo chown -R "$USER":"$USER" "$STACK_DIR"

  # -------- connector: requirements --------
  cat > "$STACK_DIR/connectors/trend-v1-opencti/requirements.txt" <<'EOF'
pycti==6.4.6
requests==2.32.3
python-magic==0.4.27
EOF

  # -------- connector: Dockerfile (with libmagic) --------
  cat > "$STACK_DIR/connectors/trend-v1-opencti/Dockerfile" <<'EOF'
FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends libmagic1 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY trend_v1_to_opencti.py .
CMD ["python", "trend_v1_to_opencti.py"]
EOF

  # -------- connector: code --------
  cat > "$STACK_DIR/connectors/trend-v1-opencti/trend_v1_to_opencti.py" <<'EOF'
import os, json, time, requests
from uuid import uuid4
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional
from pycti import OpenCTIApiClient

OPENCTI_URL   = os.getenv("OPENCTI_URL")
OPENCTI_TOKEN = os.getenv("OPENCTI_TOKEN")

URL_BASE      = os.getenv("TV1_API_ROOT", "https://api.eu.xdr.trendmicro.com").rstrip("/")
URL_PATH      = "/v3.0/threatintel/feeds"
TV1_API_KEY   = os.getenv("TV1_API_KEY")

POLL_MINUTES    = int(os.getenv("POLL_MINUTES", "60"))
SLEEP_SECONDS   = int(os.getenv("SLEEP_SECONDS", "900"))
TOP_REPORT      = int(os.getenv("TOP_REPORT", "100"))
RESPONSE_FORMAT = os.getenv("RESPONSE_FORMAT", "taxiiEnvelope")  # or stixBundle

USER_FILTER     = (os.getenv("TV1_CONTEXTUAL_FILTER") or "").strip()
TV1_LOCATION    = os.getenv("TV1_LOCATION", "No specified locations")
TV1_INDUSTRY    = os.getenv("TV1_INDUSTRY", "No specified industries")
DEBUG           = os.getenv("DEBUG","0") == "1"
MAX_OBJECTS_PER_BUNDLE = int(os.getenv("MAX_OBJECTS_PER_BUNDLE","5000"))

def log(*a): 
    if DEBUG: print(*a, flush=True)

def to_iso_z(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")

def get_json(session: requests.Session, url: str, headers: dict, params=None, max_retries=5):
    backoff = 1
    for _ in range(max_retries):
        r = session.get(url, headers=headers, params=params, timeout=60)
        ct = r.headers.get("Content-Type", "")
        log(f"[HTTP] {r.status_code} {url} CT={ct}")
        if r.status_code == 200:
            if "application/json" in ct:
                return r.json()
            raise RuntimeError(f"Unexpected content-type: {ct}")
        if r.status_code == 204:
            return {"value": [], "nextLink": None}
        if r.status_code in (429, 500, 502, 503, 504):
            time.sleep(backoff); backoff = min(backoff*2, 16); continue
        raise RuntimeError(f"HTTP {r.status_code}: {r.text[:1000]}")
    raise RuntimeError("Max retries exceeded")

def extract_items(payload):
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("value"), list):
        return payload["value"]
    return None

def collect_all(session, headers, params) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    next_url = f"{URL_BASE}{URL_PATH}"
    next_params = params
    page = 1
    while True:
        payload = get_json(session, next_url, headers, params=next_params)
        arr = extract_items(payload)
        if arr is not None:
            items.extend(arr)
            log(f"[PAGE] #{page}: +{len(arr)} (total {len(items)})")
        else:
            if isinstance(payload, dict):
                p = dict(payload); p.pop("nextLink", None)
                items.append(p)
                log(f"[PAGE] #{page}: appended single object (total {len(items)})")
        next_link = payload.get("nextLink") if isinstance(payload, dict) else None
        if not next_link:
            break
        next_url = next_link
        next_params = None
        page += 1
    return items

def flatten_objects(collected: List[Dict[str, Any]]):
    objs: List[Dict[str, Any]] = []
    for entry in collected:
        if not isinstance(entry, dict): 
            continue
        env = entry.get("envelope")
        if isinstance(env, dict) and isinstance(env.get("objects"), list):
            objs.extend(env["objects"]); continue
        content = entry.get("content")
        if isinstance(content, dict):
            if content.get("type") == "bundle" and isinstance(content.get("objects"), list):
                objs.extend(content["objects"]); continue
            cenv = content.get("envelope")
            if isinstance(cenv, dict) and isinstance(cenv.get("objects"), list):
                objs.extend(cenv["objects"]); continue
        if entry.get("type") == "bundle" and isinstance(entry.get("objects"), list):
            objs.extend(entry["objects"]); continue
        if isinstance(entry.get("objects"), list):
            objs.extend(entry["objects"]); continue
    return objs

def chunked_bundles(all_objects: List[Dict[str, Any]]):
    bundles: List[Dict[str, Any]] = []
    for i in range(0, len(all_objects), MAX_OBJECTS_PER_BUNDLE):
        chunk = all_objects[i:i+MAX_OBJECTS_PER_BUNDLE]
        if chunk:
            bundles.append({"type":"bundle","id":f"bundle--{uuid4()}","objects":chunk})
    return bundles

def run_once(client: OpenCTIApiClient):
    end_dt = datetime.utcnow()
    start_dt = end_dt - timedelta(minutes=POLL_MINUTES)
    start_iso, end_iso = to_iso_z(start_dt), to_iso_z(end_dt)

    session = requests.Session()
    session.headers.update({"Accept":"application/json"})
    headers = {"Authorization": f"Bearer {TV1_API_KEY}"}
    if USER_FILTER:
        headers["TMV1-Contextual-Filter"] = USER_FILTER
    else:
        headers["TMV1-Contextual-Filter"] = (
            f"(location eq '{TV1_LOCATION}' or location eq 'No specified locations') and industry eq '{TV1_INDUSTRY}'"
        )

    base_params = {
        "responseObjectFormat": RESPONSE_FORMAT,
        "startDateTime": start_iso,
        "endDateTime": end_iso,
    }

    fallback_sizes = [int(os.getenv("TOP_REPORT","100")), 200, 100, 50, 25, 10]
    tried, last_err = set(), None
    for size in fallback_sizes:
        if size in tried: continue
        tried.add(size)
        params = dict(base_params); params["topReport"] = size
        label = f"topReport={size}, format={RESPONSE_FORMAT}, filter={'ON' if headers.get('TMV1-Contextual-Filter') else 'OFF'}"
        try:
            log(f"[TRY] {label} | window={start_iso}..{end_iso}")
            collected = collect_all(session, headers, params)
            all_objs = flatten_objects(collected)
            if not all_objs:
                print("[INFO] No STIX objects in TAXII envelopes for current window/filter.")
                return
            bundles = chunked_bundles(all_objs)
            total_objs = sum(len(b.get("objects", [])) for b in bundles)
            for b in bundles:
                # pycti expects a JSON string
                client.stix2.import_bundle_from_json(json.dumps(b), update=True)
            print(f"[OK] Imported {len(bundles)} bundle(s), {total_objs} object(s) using {label}")
            return
        except Exception as e:
            last_err = e
            log(f"[FAIL] {label}: {e}")
            continue
    raise last_err if last_err else RuntimeError("All attempts failed")

def main():
    for k in ("OPENCTI_URL","OPENCTI_TOKEN","TV1_API_KEY"):
        if not os.getenv(k): raise SystemExit(f"Missing required env var: {k}")
    client = OpenCTIApiClient(OPENCTI_URL, OPENCTI_TOKEN)
    while True:
        try:
            run_once(client)
        except Exception as e:
            print(f"[ERROR] {e}")
        time.sleep(int(os.getenv("SLEEP_SECONDS","900")))

if __name__ == "__main__":
    main()
EOF

  # -------- docker-compose.yml --------
  cat > "$STACK_DIR/docker-compose.yml" <<EOF
version: "3.9"

services:
  redis:
    image: redis:${REDIS_VERSION}
    restart: unless-stopped
    volumes:
      - redisdata:/data

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:${ELASTIC_VERSION}
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=true
      - ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
      - bootstrap.memory_lock=true
      - ES_JAVA_OPTS=-Xms2g -Xmx2g
      - thread_pool.search.queue_size=5000
    ulimits:
      memlock:
        soft: -1
        hard: -1
    restart: unless-stopped
    volumes:
      - esdata:/usr/share/elasticsearch/data

  minio:
    image: minio/minio:${MINIO_VERSION}
    command: server /data
    environment:
      - MINIO_ROOT_USER=${MINIO_ROOT_USER}
      - MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
    ports:
      - "9000:9000"
      - "9001:9001"
    restart: unless-stopped
    volumes:
      - s3data:/data

  rabbitmq:
    image: rabbitmq:${RABBIT_VERSION}
    environment:
      - RABBITMQ_DEFAULT_USER=${RABBITMQ_DEFAULT_USER}
      - RABBITMQ_DEFAULT_PASS=${RABBITMQ_DEFAULT_PASS}
    restart: unless-stopped
    volumes:
      - rabbitmqdata:/var/lib/rabbitmq

  neo4j:
    image: neo4j:${NEO4J_VERSION}
    environment:
      - NEO4J_AUTH=neo4j/${NEO4J_PASSWORD}
      - NEO4J_dbms_security_authentication__providers=native
      - NEO4J_dbms_memory_heap_initial__size=1G
      - NEO4J_dbms_memory_heap_max__size=2G
      - NEO4J_dbms_memory_pagecache_size=1G
    restart: unless-stopped
    volumes:
      - neo4jdata:/data
      - neo4jlogs:/logs

  opencti:
    image: opencti/platform:${OPENCTI_VERSION}
    depends_on:
      - redis
      - elasticsearch
      - minio
      - rabbitmq
      - neo4j
    environment:
      APP__PORT: "8080"
      APP__BASE_URL: "http://localhost:${OPENCTI_PORT}"
      APP__ADMIN__EMAIL: "${OPENCTI_ADMIN_EMAIL}"
      APP__ADMIN__PASSWORD: "${OPENCTI_ADMIN_PASS}"
      APP__ADMIN__TOKEN: "${OPENCTI_ADMIN_TOKEN}"

      # Enable local (email/password) auth
      PROVIDERS__LOCAL__STRATEGY: "LocalStrategy"

      REDIS__HOSTNAME: "redis"
      ELASTICSEARCH__URL: "http://elasticsearch:9200"
      ELASTICSEARCH__SSL__REJECT_UNAUTHORIZED: "false"
      ELASTICSEARCH__USERNAME: "elastic"
      ELASTICSEARCH__PASSWORD: "${ELASTIC_PASSWORD}"

      MINIO__ENDPOINT: "minio"
      MINIO__PORT: "9000"
      MINIO__USE_SSL: "false"
      MINIO__ACCESS_KEY: "${MINIO_ROOT_USER}"
      MINIO__SECRET_KEY: "${MINIO_ROOT_PASSWORD}"

      RABBITMQ__HOSTNAME: "rabbitmq"
      RABBITMQ__PORT: "5672"
      RABBITMQ__USERNAME: "${RABBITMQ_DEFAULT_USER}"
      RABBITMQ__PASSWORD: "${RABBITMQ_DEFAULT_PASS}"

      NEO4J__ENCRYPTION: "false"
      NEO4J__URI: "bolt://neo4j:7687"
      NEO4J__USERNAME: "neo4j"
      NEO4J__PASSWORD: "${NEO4J_PASSWORD}"

      SMTP__HOSTNAME: ""
    ports:
      - "${OPENCTI_PORT}:8080"
    restart: unless-stopped
    volumes:
      - openctidata:/opencti-data

  worker:
    image: opencti/worker:${OPENCTI_VERSION}
    depends_on:
      - opencti
    environment:
      OPENCTI_URL: "http://opencti:8080"
      OPENCTI_TOKEN: "${OPENCTI_ADMIN_TOKEN}"
      WORKER_LOG_LEVEL: "info"
    restart: unless-stopped

  connector-trend-v1:
    build:
      context: ./connectors/trend-v1-opencti
    depends_on:
      - opencti
    environment:
      OPENCTI_URL: "http://opencti:8080"
      OPENCTI_TOKEN: "${OPENCTI_ADMIN_TOKEN}"

      TV1_API_ROOT: "${TV1_API_ROOT}"
      TV1_API_KEY: "${TV1_API_KEY}"
      TV1_CONTEXTUAL_FILTER: "${TV1_CONTEXTUAL_FILTER}"
      TV1_LOCATION: "${TV1_LOCATION}"
      TV1_INDUSTRY: "${TV1_INDUSTRY}"

      POLL_MINUTES: "${POLL_MINUTES}"
      SLEEP_SECONDS: "${SLEEP_SECONDS}"
      TOP_REPORT: "${TOP_REPORT}"
      RESPONSE_FORMAT: "${RESPONSE_FORMAT}"
    restart: unless-stopped
EOF

  if [[ "$WITH_OPENBAS" == "yes" ]]; then
    cat >> "$STACK_DIR/docker-compose.yml" <<EOF

  # ---------- OpenBAS (optional) ----------
  postgres:
    image: postgres:${POSTGRES_VERSION}
    environment:
      - POSTGRES_DB=${POSTGRES_DB}
      - POSTGRES_USER=${POSTGRES_USER}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
    restart: unless-stopped
    volumes:
      - pgdata:/var/lib/postgresql/data

  openbas:
    image: openbas/platform:${OPENBAS_VERSION}
    depends_on:
      - postgres
      - redis
      - minio
      - rabbitmq
    environment:
      APP__PORT: "4000"
      APP__BASE_URL: "http://localhost:${OPENBAS_PORT}"
      APP__ADMIN__EMAIL: "${OPENBAS_ADMIN_EMAIL}"
      APP__ADMIN__PASSWORD: "${OPENBAS_ADMIN_PASS}"
      APP__ADMIN__TOKEN: "${OPENBAS_ADMIN_TOKEN}"

      # Database (PostgreSQL)
      DATABASE__CLIENT: "postgresql"
      DATABASE__HOST: "postgres"
      DATABASE__PORT: "5432"
      DATABASE__NAME: "${POSTGRES_DB}"
      DATABASE__USERNAME: "${POSTGRES_USER}"
      DATABASE__PASSWORD: "${POSTGRES_PASSWORD}"

      # Shared services
      REDIS__HOSTNAME: "redis"
      MINIO__ENDPOINT: "minio"
      MINIO__PORT: "9000"
      MINIO__USE_SSL: "false"
      MINIO__ACCESS_KEY: "${MINIO_ROOT_USER}"
      MINIO__SECRET_KEY: "${MINIO_ROOT_PASSWORD}"
      RABBITMQ__HOSTNAME: "rabbitmq"
      RABBITMQ__PORT: "5672"
      RABBITMQ__USERNAME: "${RABBITMQ_DEFAULT_USER}"
      RABBITMQ__PASSWORD: "${RABBITMQ_DEFAULT_PASS}"

      # Enable local auth for OpenBAS as well
      PROVIDERS__LOCAL__STRATEGY: "LocalStrategy"
    ports:
      - "${OPENBAS_PORT}:4000"
    restart: unless-stopped

  openbas-worker:
    image: openbas/worker:${OPENBAS_VERSION}
    depends_on:
      - openbas
    environment:
      OPENBAS_URL: "http://openbas:4000"
      OPENBAS_TOKEN: "${OPENBAS_ADMIN_TOKEN}"
      WORKER_LOG_LEVEL: "info"
    restart: unless-stopped
EOF
  fi

  cat >> "$STACK_DIR/docker-compose.yml" <<'EOF'

volumes:
  esdata:
  s3data:
  rabbitmqdata:
  redisdata:
  neo4jdata:
  neo4jlogs:
  openctidata:
  pgdata:
EOF

  # -------- .env (overwrite each run) --------
  cat > "$STACK_DIR/.env" <<EOF
# Auto-generated by install_opencti.sh
OPENCTI_PORT=${OPENCTI_PORT}

OPENCTI_ADMIN_EMAIL=${OPENCTI_ADMIN_EMAIL}
OPENCTI_ADMIN_PASS=${OPENCTI_ADMIN_PASS}
OPENCTI_ADMIN_TOKEN=${OPENCTI_ADMIN_TOKEN}

ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
RABBITMQ_DEFAULT_USER=${RABBITMQ_DEFAULT_USER}
RABBITMQ_DEFAULT_PASS=${RABBITMQ_DEFAULT_PASS}
NEO4J_PASSWORD=${NEO4J_PASSWORD}

TV1_API_ROOT=${TV1_API_ROOT}
TV1_API_KEY=${TV1_API_KEY}
TV1_CONTEXTUAL_FILTER=${TV1_CONTEXTUAL_FILTER}
TV1_LOCATION=${TV1_LOCATION}
TV1_INDUSTRY=${TV1_INDUSTRY}

POLL_MINUTES=${POLL_MINUTES}
SLEEP_SECONDS=${SLEEP_SECONDS}
TOP_REPORT=${TOP_REPORT}
RESPONSE_FORMAT=${RESPONSE_FORMAT}
EOF

  if [[ "$WITH_OPENBAS" == "yes" ]]; then
    cat >> "$STACK_DIR/.env" <<EOF
OPENBAS_PORT=${OPENBAS_PORT}
OPENBAS_ADMIN_EMAIL=${OPENBAS_ADMIN_EMAIL}
OPENBAS_ADMIN_PASS=${OPENBAS_ADMIN_PASS}
OPENBAS_ADMIN_TOKEN=${OPENBAS_ADMIN_TOKEN}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
EOF
  fi

  echo
  echo "[i] Files written to $STACK_DIR"
  echo "    - docker-compose.yml"
  echo "    - connectors/trend-v1-opencti/*"
  echo "    - .env (all vars, overwritten each run)"
}

bring_up() {
  pushd "$STACK_DIR" >/dev/null
  echo "[*] Building Trend connector image..."
  docker compose build connector-trend-v1

  echo "[*] Starting stack..."
  docker compose up -d

  echo
  echo "[✔] OpenCTI:  http://localhost:${OPENCTI_PORT}"
  echo "    Admin user : ${OPENCTI_ADMIN_EMAIL}"
  echo "    Admin pass : ${OPENCTI_ADMIN_PASS}"
  echo "    Admin token: ${OPENCTI_ADMIN_TOKEN}"

  if [[ "$WITH_OPENBAS" == "yes" ]]; then
    echo
    echo "[✔] OpenBAS:   http://localhost:${OPENBAS_PORT}"
    echo "    Admin user : ${OPENBAS_ADMIN_EMAIL}"
    echo "    Admin pass : ${OPENBAS_ADMIN_PASS}"
    echo "    Admin token: ${OPENBAS_ADMIN_TOKEN}"
  fi

  echo
  echo "Trend V1 root: ${TV1_API_ROOT}"
  echo "(Update TV1_API_KEY in $STACK_DIR/.env if needed)"
  popd >/dev/null
}

main() {
  maybe_install_docker
  ensure_secrets
  wipe_stack_if_requested
  write_files
  bring_up
}

main