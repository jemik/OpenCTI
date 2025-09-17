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
CONNECTOR_POLL_MINUTES="${CONNECTOR_POLL_MINUTES:-60}"
CONNECTOR_SLEEP_SECONDS="${CONNECTOR_SLEEP_SECONDS:-900}"
CONNECTOR_TOP_REPORT="${CONNECTOR_TOP_REPORT:-1000}"
CONNECTOR_RESPONSE_FORMAT="${CONNECTOR_RESPONSE_FORMAT:-stixBundle}"

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
EOF

  cat > "$STACK_DIR/connectors/trend-v1-opencti/Dockerfile" <<'EOF'
FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY trend_v1_to_opencti.py .
CMD ["python", "trend_v1_to_opencti.py"]
EOF

  cat > "$STACK_DIR/connectors/trend-v1-opencti/trend_v1_to_opencti.py" <<'EOF'
import os, time, json, datetime, requests
from pycti import OpenCTIApiClient

OPENCTI_URL   = os.getenv("OPENCTI_URL")
OPENCTI_TOKEN = os.getenv("OPENCTI_TOKEN")

TV1_API_ROOT  = os.getenv("TV1_API_ROOT", "https://api.eu.xdr.trendmicro.com")
TV1_API_KEY   = os.getenv("TV1_API_KEY")
TV1_PATH_FEED = "/v3.0/threatintel/feeds"
TV1_PATH_FDEF = "/v3.0/threatintel/feeds/filterDefinition"

POLL_MINUTES      = int(os.getenv("POLL_MINUTES", "60"))
SLEEP_SECONDS     = int(os.getenv("SLEEP_SECONDS", "900"))
TOP_REPORT        = int(os.getenv("TOP_REPORT", "1000"))
RESPONSE_FORMAT   = os.getenv("RESPONSE_FORMAT", "stixBundle")
CONTEXTUAL_FILTER = os.getenv("TV1_CONTEXTUAL_FILTER", "").strip()

http = requests.Session()
http.headers.update({"Authorization": f"Bearer {TV1_API_KEY}", "Accept": "application/json"})

def iso_now():
    return datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z"

def iso_minus_minutes(m):
    return (datetime.datetime.utcnow() - datetime.timedelta(minutes=m)).replace(microsecond=0).isoformat() + "Z"

def fetch_filter_definition():
    url = TV1_API_ROOT + TV1_PATH_FDEF
    r = http.get(url, timeout=30)
    r.raise_for_status()
    return r.json()

def fetch_feed(start_iso: str, end_iso: str):
    url = TV1_API_ROOT + TV1_PATH_FEED
    params = {
        "startDateTime": start_iso,
        "endDateTime": end_iso,
        "topReport": TOP_REPORT,
        "responseObjectFormat": RESPONSE_FORMAT,
    }
    headers = {}
    if CONTEXTUAL_FILTER:
        headers["TMV1-Contextual-Filter"] = CONTEXTUAL_FILTER
    r = http.get(url, params=params, headers=headers or None, timeout=90)
    if r.status_code == 429:
        time.sleep(65)
        r = http.get(url, params=params, headers=headers or None, timeout=90)
    r.raise_for_status()
    if "application/json" in r.headers.get("Content-Type", ""):
        return r.json()
    return r.text

def import_bundle(client: OpenCTIApiClient, bundle_json: dict):
    client.stix2.import_bundle_from_json(bundle_json, update=True)

def run_once(client: OpenCTIApiClient):
    end_iso, start_iso = iso_now(), iso_minus_minutes(POLL_MINUTES)
    data = fetch_feed(start_iso, end_iso)
    if RESPONSE_FORMAT == "stixBundle" and isinstance(data, dict) and data.get("type") == "bundle":
        import_bundle(client, data)
        print(f"[OK] Ingested bundle ({len(data.get('objects', []))} objs) window {start_iso} → {end_iso}")
        return
    if isinstance(data, dict) and "items" in data:
        count = 0
        for item in data["items"]:
            content = item.get("content")
            if isinstance(content, dict) and content.get("type") == "bundle":
                import_bundle(client, content)
                count += 1
        print(f"[OK] Ingested {count} envelope item(s) window {start_iso} → {end_iso}")
        return
    print("[WARN] Response not recognized as STIX bundle/envelope:")
    print(json.dumps(data, indent=2)[:2000])

def main():
    if not all([OPENCTI_URL, OPENCTI_TOKEN, TV1_API_KEY]):
        raise SystemExit("Missing OPENCTI_URL, OPENCTI_TOKEN, or TV1_API_KEY")
    client = OpenCTIApiClient(OPENCTI_URL, OPENCTI_TOKEN)
    try:
        fdef = fetch_filter_definition()
        print("[info] filterDefinition keys:", list(fdef.keys()))
    except Exception as e:
        print(f"[info] filterDefinition not retrieved: {e}")
    while True:
        try:
            run_once(client)
        except requests.HTTPError as e:
            body = getattr(e.response, "text", "")[:800]
            print(f"[HTTP ERROR] {e}\n{body}")
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