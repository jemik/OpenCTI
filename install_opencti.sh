#!/usr/bin/env bash
set -euo pipefail

# -------- Settings (override via env or edit below) --------
STACK_DIR="${STACK_DIR:-/opt/opencti}"
OPENCTI_VERSION="${OPENCTI_VERSION:-6.4.6}"
ELASTIC_VERSION="${ELASTIC_VERSION:-8.13.4}"
NEO4J_VERSION="${NEO4J_VERSION:-5.19.0}"
MINIO_VERSION="${MINIO_VERSION:-RELEASE.2024-06-13T22-53-53Z}"
RABBIT_VERSION="${RABBIT_VERSION:-3.13-management}"
REDIS_VERSION="${REDIS_VERSION:-7.2}"

OPENCTI_PORT="${OPENCTI_PORT:-8080}"

# Secrets (autogenerate if empty)
OPENCTI_ADMIN_EMAIL="${OPENCTI_ADMIN_EMAIL:-admin@local.local}"
OPENCTI_ADMIN_PASS="${OPENCTI_ADMIN_PASS:-}"
OPENCTI_ADMIN_TOKEN="${OPENCTI_ADMIN_TOKEN:-}"  # Admin API token (will generate if empty)
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-}"
RABBITMQ_DEFAULT_USER="${RABBITMQ_DEFAULT_USER:-opencti}"
RABBITMQ_DEFAULT_PASS="${RABBITMQ_DEFAULT_PASS:-}"
NEO4J_PASSWORD="${NEO4J_PASSWORD:-}"

# Connector (fill your values here)
TV1_API_ROOT="${TV1_API_ROOT:-https://api.eu.xdr.trendmicro.com}"
TV1_API_KEY="${TV1_API_KEY:-CHANGEME_TREND_V1_API_KEY}"
TV1_CONTEXTUAL_FILTER="${TV1_CONTEXTUAL_FILTER:-}"   # optional filter, e.g. "location eq 'Denmark' and industry in ('Finance','Energy')"
CONNECTOR_POLL_MINUTES="${CONNECTOR_POLL_MINUTES:-4320}"
CONNECTOR_SLEEP_SECONDS="${CONNECTOR_SLEEP_SECONDS:-900}"
CONNECTOR_TOP_REPORT="${CONNECTOR_TOP_REPORT:-1000}"
CONNECTOR_RESPONSE_FORMAT="${CONNECTOR_RESPONSE_FORMAT:-taxiiEnvelope}"

# -----------------------------------------------------------

maybe_install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "[*] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER" || true
    echo "[*] Docker installed."
  fi

  if ! docker compose version >/dev/null 2>&1; then
    echo "[*] Installing Docker Compose plugin..."
    # Minimal cross-distro attempt
    if command -v apt >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
      sudo yum install -y docker-compose-plugin
    else
      echo "(!) Please install Docker Compose plugin manually."
    fi
  fi

  # Increase vm.max_map_count for Elasticsearch
  echo "[*] Configuring vm.max_map_count=1048575 for Elasticsearch..."
  sudo sysctl -w vm.max_map_count=1048575 || true
  # Persist the setting (optional)
  sudo grep -q vm.max_map_count /etc/sysctl.conf || echo "vm.max_map_count=1048575" | sudo tee -a /etc/sysctl.conf >/dev/null
}

rand() { openssl rand -hex 24; }

ensure_secrets() {
  [[ -n "$OPENCTI_ADMIN_PASS" ]] || OPENCTI_ADMIN_PASS="$(rand)"
  [[ -n "$MINIO_ROOT_PASSWORD" ]] || MINIO_ROOT_PASSWORD="$(rand)"
  [[ -n "$ELASTIC_PASSWORD" ]] || ELASTIC_PASSWORD="$(rand)"
  [[ -n "$RABBITMQ_DEFAULT_PASS" ]] || RABBITMQ_DEFAULT_PASS="$(rand)"
  [[ -n "$NEO4J_PASSWORD" ]] || NEO4J_PASSWORD="$(rand)"
  [[ -n "$OPENCTI_ADMIN_TOKEN" ]] || OPENCTI_ADMIN_TOKEN="$(cat /proc/sys/kernel/random/uuid)"
}

write_files() {
  sudo mkdir -p "$STACK_DIR/connectors/trend-v1-opencti"
  sudo chown -R "$USER":"$USER" "$STACK_DIR"

  # Connector files
  cat > "$STACK_DIR/connectors/trend-v1-opencti/requirements.txt" <<'EOF'
pycti==6.4.6
requests==2.32.3
python-magic==0.4.27
EOF

  cat > "$STACK_DIR/connectors/trend-v1-opencti/Dockerfile" <<'EOF'
FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app

# --- add native lib for python-magic ---
RUN apt-get update && \
    apt-get install -y --no-install-recommends libmagic1 && \
    rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY trend_v1_to_opencti.py .
CMD ["python", "trend_v1_to_opencti.py"]
EOF

  cat > "$STACK_DIR/connectors/trend-v1-opencti/trend_v1_to_opencti.py" <<'EOF'
import os
import json
import time
import requests
from uuid import uuid4
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional, Tuple
from pycti import OpenCTIApiClient

# -------- OpenCTI env --------
OPENCTI_URL   = os.getenv("OPENCTI_URL")
OPENCTI_TOKEN = os.getenv("OPENCTI_TOKEN")

# -------- Trend Vision One env --------
URL_BASE      = os.getenv("TV1_API_ROOT", "https://api.eu.xdr.trendmicro.com").rstrip("/")
URL_PATH      = "/v3.0/threatintel/feeds"
TV1_API_KEY   = os.getenv("TV1_API_KEY")

# -------- Feed options --------
POLL_MINUTES        = int(os.getenv("POLL_MINUTES", "60"))
RESPONSE_FORMAT     = os.getenv("RESPONSE_FORMAT", "taxiiEnvelope")  # or "stixBundle"
TOP_REPORT_DEFAULT  = int(os.getenv("TOP_REPORT", "100"))            # requested per-page size
SLEEP_SECONDS       = int(os.getenv("SLEEP_SECONDS", "900"))

# Contextual filter:
# If TV1_CONTEXTUAL_FILTER is given, we use it as-is.
# Else we construct the header from TV1_LOCATION / TV1_INDUSTRY (defaults match your sample).
USER_FILTER         = ("").strip()
TV1_LOCATION        = os.getenv("TV1_LOCATION", "No specified locations")
TV1_INDUSTRY        = os.getenv("TV1_INDUSTRY", "No specified industries")

DEBUG               = os.getenv("DEBUG", "0") == "1"

# Optional: keep bundles at a sane size for OpenCTI imports.
MAX_OBJECTS_PER_BUNDLE = int(os.getenv("MAX_OBJECTS_PER_BUNDLE", "5000"))

def to_iso_z(dt: datetime) -> str:
    # match your sample with milliseconds set to .000Z
    return dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")

def log(*a):
    if DEBUG: print(*a, flush=True)

def get_json(session: requests.Session, url: str, headers: dict, params=None, max_retries=5):
    backoff = 1
    for _ in range(max_retries):
        resp = session.get(url, headers=headers, params=params, timeout=60)
        ct = resp.headers.get("Content-Type", "")
        log(f"[HTTP] {resp.status_code} {url}  CT={ct}")
        if resp.status_code == 200:
            if "application/json" in ct:
                return resp.json()
            raise RuntimeError(f"Unexpected content-type: {ct}")
        if resp.status_code == 204:
            # No content is a valid response → treat like empty page
            return {"value": [], "nextLink": None}
        if resp.status_code in (429, 500, 502, 503, 504):
            time.sleep(backoff)
            backoff = min(backoff * 2, 16)
            continue
        # surface server error body for 400/401/etc.
        raise RuntimeError(f"HTTP {resp.status_code}: {resp.text[:1000]}")
    raise RuntimeError("Max retries exceeded")

def extract_items(payload):
    # Exactly like your sample
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict) and isinstance(payload.get("value"), list):
        return payload["value"]
    return None

def collect_all(session, headers, params, debug=False) -> List[Dict[str, Any]]:
    items: List[Dict[str, Any]] = []
    next_url = f"{URL_BASE}{URL_PATH}"
    next_params = params
    page = 1
    while True:
        payload = get_json(session, next_url, headers, params=next_params)
        arr = extract_items(payload)
        if arr is not None:
            items.extend(arr)
            if debug:
                print(f"Fetched page {page}: {len(arr)} items; total {len(items)}")
        else:
            if isinstance(payload, dict):
                p = dict(payload)
                p.pop("nextLink", None)
                items.append(p)
                if debug:
                    print(f"Fetched page {page}: appended full page object (no 'value' array).")
        next_link = payload.get("nextLink") if isinstance(payload, dict) else None
        if not next_link:
            break
        next_url = next_link
        next_params = None  # important: nextLink already has its own query
        page += 1
    return items

def flatten_objects_from_items(collected: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Pull STIX objects out of the common shapes we see:
      A) {"envelope":{"objects":[...]}}  <-- your tenant returns this
      B) {"content":{"type":"bundle","objects":[...]}}
      C) {"type":"bundle","objects":[...]}
      D) {"objects":[...]}  (raw)
    Returns a flat list of STIX objects.
    """
    objs: List[Dict[str, Any]] = []
    for entry in collected:
        if not isinstance(entry, dict):
            continue

        # A) TAXII envelope (exactly like your working sample)
        env = entry.get("envelope")
        if isinstance(env, dict) and isinstance(env.get("objects"), list):
            objs.extend(env["objects"])
            continue

        # B) content as bundle
        content = entry.get("content")
        if isinstance(content, dict):
            if content.get("type") == "bundle" and isinstance(content.get("objects"), list):
                objs.extend(content["objects"])
                continue
            cenv = content.get("envelope")
            if isinstance(cenv, dict) and isinstance(cenv.get("objects"), list):
                objs.extend(cenv["objects"])
                continue

        # C) direct bundle on the item
        if entry.get("type") == "bundle" and isinstance(entry.get("objects"), list):
            objs.extend(entry["objects"])
            continue

        # D) raw objects list
        if isinstance(entry.get("objects"), list):
            objs.extend(entry["objects"])
            continue

    return objs

def chunked_bundles(all_objects: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Split a flat object list into STIX bundles (≤ MAX_OBJECTS_PER_BUNDLE)."""
    bundles: List[Dict[str, Any]] = []
    if not all_objects:
        return bundles
    for i in range(0, len(all_objects), MAX_OBJECTS_PER_BUNDLE):
        chunk = all_objects[i:i+MAX_OBJECTS_PER_BUNDLE]
        if not chunk:
            continue
        bundles.append({"type": "bundle", "id": f"bundle--{uuid4()}", "objects": chunk})
    return bundles

def run_once(client: OpenCTIApiClient):
    # build time window (UTC)
    end_dt = datetime.utcnow()
    start_dt = end_dt - timedelta(minutes=POLL_MINUTES)
    start_iso = to_iso_z(start_dt)
    end_iso   = to_iso_z(end_dt)

    # build session + headers
    session = requests.Session()
    session.headers.update({"Accept": "application/json"})  # explicit
    headers = {
        "Authorization": f"Bearer {TV1_API_KEY}",
    }
    if USER_FILTER:
        headers["TMV1-Contextual-Filter"] = USER_FILTER
    else:
        # (location eq '<loc>' OR location eq 'No specified locations') AND industry eq '<industry>'
        headers["TMV1-Contextual-Filter"] = (
            f"(location eq 'No specified locations') "
            f"and industry eq '{TV1_INDUSTRY}'"
        )

    base_params = {
        "responseObjectFormat": RESPONSE_FORMAT,   # "taxiiEnvelope" (default) or "stixBundle"
        "startDateTime": start_iso,
        "endDateTime": end_iso,
    }

    # fallback sizes order (matches your sample tool)
    fallback_sizes = [TOP_REPORT_DEFAULT, 200, 100, 50, 25, 10]
    tried = set()
    last_err: Optional[Exception] = None

    # fetch + import
    for size in fallback_sizes:
        if size in tried:
            continue
        tried.add(size)
        params = dict(base_params)
        params["topReport"] = size
        label = f"topReport={size}, format={RESPONSE_FORMAT}, filter=ON, end=ON"
        try:
            log(f"Trying: {label} | params={params}")
            collected = collect_all(session, headers, params, debug=DEBUG)

            # Flatten TAXII envelopes & other shapes into STIX objects, then wrap into bundles
            all_objs = flatten_objects_from_items(collected)
            if not all_objs:
                print("[INFO] No STIX objects in TAXII envelopes for current window/filter.")
                return

            bundles = chunked_bundles(all_objs)
            total_objs = sum(len(b.get("objects", [])) for b in bundles)
            for b in bundles:
                # IMPORTANT: pycti expects a JSON string for import_bundle_from_json
                client.stix2.import_bundle_from_json(json.dumps(b), update=True)
            print(f"[OK] Imported {len(bundles)} bundle(s), {total_objs} object(s) using {label}")
            return
        except Exception as e:
            if DEBUG:
                print(f"Attempt failed ({label}): {e}")
            last_err = e
            continue

    raise last_err if last_err else RuntimeError("All attempts failed")

def main():
    if not OPENCTI_URL or not OPENCTI_TOKEN or not TV1_API_KEY:
        missing = [k for k,v in [("OPENCTI_URL",OPENCTI_URL),("OPENCTI_TOKEN",OPENCTI_TOKEN),("TV1_API_KEY",TV1_API_KEY)] if not v]
        raise SystemExit(f"Missing required env var(s): {', '.join(missing)}")

    client = OpenCTIApiClient(OPENCTI_URL, OPENCTI_TOKEN)
    while True:
        try:
            run_once(client)
        except Exception as e:
            print(f"[ERROR] {e}")
        time.sleep(SLEEP_SECONDS)

if __name__ == "__main__":
    main()
EOF

  # Docker Compose file
  cat > "$STACK_DIR/docker-compose.yml" <<EOF
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
      - APP__PORT=8080
      - APP__BASE_URL=http://localhost:${OPENCTI_PORT}
      - APP__ADMIN__EMAIL=${OPENCTI_ADMIN_EMAIL}
      - APP__ADMIN__PASSWORD=${OPENCTI_ADMIN_PASS}
      - APP__ADMIN__TOKEN=\${OPENCTI_ADMIN_TOKEN}
      - PROVIDERS__LOCAL__STRATEGY=LocalStrategy
      - REDIS__HOSTNAME=redis
      - ELASTICSEARCH__URL=http://elasticsearch:9200
      - ELASTICSEARCH__SSL__REJECT_UNAUTHORIZED=false
      - ELASTICSEARCH__USERNAME=elastic
      - ELASTICSEARCH__PASSWORD=${ELASTIC_PASSWORD}
      - MINIO__ENDPOINT=minio
      - MINIO__PORT=9000
      - MINIO__USE_SSL=false
      - MINIO__ACCESS_KEY=${MINIO_ROOT_USER}
      - MINIO__SECRET_KEY=${MINIO_ROOT_PASSWORD}
      - RABBITMQ__HOSTNAME=rabbitmq
      - RABBITMQ__PORT=5672
      - RABBITMQ__PORT_MANAGEMENT=15672
      - RABBITMQ__MANAGEMENT_SSL=false
      - RABBITMQ__USERNAME=${RABBITMQ_DEFAULT_USER}
      - RABBITMQ__PASSWORD=${RABBITMQ_DEFAULT_PASS}
      - NEO4J__ENCRYPTION=false
      - NEO4J__URI=bolt://neo4j:7687
      - NEO4J__USERNAME=neo4j
      - NEO4J__PASSWORD=${NEO4J_PASSWORD}
      - SMTP__HOSTNAME=
      - PROVIDERS__LOCAL=true
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
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=\${OPENCTI_ADMIN_TOKEN}
      - WORKER_LOG_LEVEL=info
    restart: unless-stopped

  # --- Trend Vision One Threat Intel connector ---
  connector-trend-v1:
    build:
      context: ./connectors/trend-v1-opencti
    depends_on:
      - opencti
    environment:
      - OPENCTI_URL=http://opencti:8080
      - OPENCTI_TOKEN=\${OPENCTI_ADMIN_TOKEN}
      - TV1_API_ROOT=${TV1_API_ROOT}
      - TV1_API_KEY=${TV1_API_KEY}
      - RESPONSE_FORMAT=${CONNECTOR_RESPONSE_FORMAT}
      - TOP_REPORT=${CONNECTOR_TOP_REPORT}
      - POLL_MINUTES=${CONNECTOR_POLL_MINUTES}
      - SLEEP_SECONDS=${CONNECTOR_SLEEP_SECONDS}
      - TV1_CONTEXTUAL_FILTER=${TV1_CONTEXTUAL_FILTER}
    restart: unless-stopped

volumes:
  esdata:
  s3data:
  rabbitmqdata:
  redisdata:
  neo4jdata:
  neo4jlogs:
  openctidata:
EOF

  # .env file with the OpenCTI admin token (for Docker Compose substitution)
  cat > "$STACK_DIR/.env" <<EOF
# Environment file for Docker Compose
OPENCTI_ADMIN_TOKEN=${OPENCTI_ADMIN_TOKEN}
EOF

  echo
  echo "[i] Files written to $STACK_DIR"
  echo "    - docker-compose.yml (with persistent volumes and updated settings)"
  echo "    - connectors/trend-v1-opencti/* (connector code and Dockerfile)"
  echo "    - .env (contains OPENCTI_ADMIN_TOKEN for connector/worker use)"
}

bring_up() {
  pushd "$STACK_DIR" >/dev/null
  echo "[*] Building connector image..."
  docker compose build connector-trend-v1

  echo "[*] Starting OpenCTI stack..."
  docker compose up -d

  echo
  echo "[✔] OpenCTI is starting on http://localhost:${OPENCTI_PORT}"
  echo "    Admin user: ${OPENCTI_ADMIN_EMAIL}"
  echo "    Admin pass: ${OPENCTI_ADMIN_PASS}"
  echo
  echo "    The connector and worker use OPENCTI_ADMIN_TOKEN from $STACK_DIR/.env"
  echo "    IMPORTANT: Update TV1_API_KEY (currently: ${TV1_API_KEY}) and TV1_CONTEXTUAL_FILTER as needed before first run."
  popd >/dev/null
}

main() {
  maybe_install_docker
  ensure_secrets
  write_files
  bring_up
}

main