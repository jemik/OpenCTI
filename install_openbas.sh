#!/bin/bash
# install_openbas.sh - Automated OpenBAS deployment (with Traefik, PostgreSQL, MinIO, Redis, RabbitMQ)
# This script sets up OpenBAS and its dependencies in Docker, following the official architecture [oai_citation:4‡docs.openbas.io](https://docs.openbas.io/latest/deployment/installation/#:~:text=Whether%20you%20are%20using%20one,the%20mandatory%20parameters%20to%20fill).
# It creates a dedicated Docker Compose project ("openbas") to avoid conflicts with any existing OpenCTI stack.

set -euo pipefail

# Directory setup (use /opt/openbas or current dir)
INSTALL_DIR="${INSTALL_DIR:-$PWD/openbas-stack}"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Working in $INSTALL_DIR"

# Generate random credentials for security (you can customize these or set as env vars before running)
POSTGRES_USER="${POSTGRES_USER:-openbas}"                      # PostgreSQL username (default 'openbas')
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}"
RABBIT_USER="${RABBITMQ_DEFAULT_USER:-openbas}"
RABBIT_PASSWORD="${RABBITMQ_DEFAULT_PASS:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-openbasminio}"             # MinIO admin username
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)}"
OPENBAS_ADMIN_EMAIL="${OPENBAS_ADMIN_EMAIL:-admin@example.com}" # OpenBAS admin email (change to a real address)
OPENBAS_ADMIN_PASSWORD="${OPENBAS_ADMIN_PASSWORD:-$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)}"
OPENBAS_ADMIN_TOKEN="${OPENBAS_ADMIN_TOKEN:-$(cat /proc/sys/kernel/random/uuid)}"  # Admin API token (UUID) [oai_citation:5‡docs.openbas.io](https://docs.openbas.io/latest/deployment/installation/#:~:text=OPENBAS_ADMIN_EMAIL%3DChangeMe%40example.com%20,No%20need%20for%20change)

# Domain/host configuration for Traefik and OpenBAS access
OPENBAS_HOST="${OPENBAS_HOST:-openbas.example.com}"  # Change this to the domain or hostname for OpenBAS UI
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-user@example.com}"  # Email for Let's Encrypt certificate registration

# Write the .env file for Docker Compose with all necessary environment variables [oai_citation:6‡docs.openbas.io](https://docs.openbas.io/latest/deployment/installation/#:~:text=Whether%20you%20are%20using%20one,the%20mandatory%20parameters%20to%20fill) [oai_citation:7‡docs.openbas.io](https://docs.openbas.io/latest/deployment/installation/#:~:text=OPENBAS_ADMIN_EMAIL%3DChangeMe%40example.com%20,No%20need%20for%20change)
cat > .env <<-EOF
#----------------- OpenBAS Environment Configuration -----------------#
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
KEYSTORE_PASSWORD=${KEYSTORE_PASSWORD:-ChangeMe}   # Used for securing OpenBAS (e.g., keystore for HTTPS), customize as needed
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}
RABBITMQ_DEFAULT_USER=${RABBIT_USER}
RABBITMQ_DEFAULT_PASS=${RABBIT_PASSWORD}
SPRING_MAIL_HOST=${SPRING_MAIL_HOST:-smtp.example.com}
SPRING_MAIL_PORT=${SPRING_MAIL_PORT:-465}
SPRING_MAIL_USERNAME=${SPRING_MAIL_USERNAME:-no-reply@example.com}
SPRING_MAIL_PASSWORD=${SPRING_MAIL_PASSWORD:-ChangeMeEmailPassword}
OPENBAS_MAIL_IMAP_ENABLED=${OPENBAS_MAIL_IMAP_ENABLED:-true}
OPENBAS_MAIL_IMAP_HOST=${OPENBAS_MAIL_IMAP_HOST:-imap.example.com}
OPENBAS_MAIL_IMAP_PORT=${OPENBAS_MAIL_IMAP_PORT:-993}
OPENBAS_ADMIN_EMAIL=${OPENBAS_ADMIN_EMAIL}
OPENBAS_ADMIN_PASSWORD=${OPENBAS_ADMIN_PASSWORD}
OPENBAS_ADMIN_TOKEN=${OPENBAS_ADMIN_TOKEN}
# Pre-defined collector IDs (do not change unless advised) [oai_citation:8‡docs.openbas.io](https://docs.openbas.io/latest/deployment/installation/#:~:text=OPENBAS_ADMIN_TOKEN%3DChangeMe%20,No%20need%20for%20change)
COLLECTOR_MITRE_ATTACK_ID=3050d2a3-291d-44eb-8038-b4e7dd107436
COLLECTOR_ATOMIC_OPENBAS_ID=63544750-19a1-435f-ada4-b44e39cf3cdb
COLLECTOR_ATOMIC_RED_TEAM_ID=c34e3f19-e0b9-45cb-83e0-3b329e4c53d3

# Traefik/Domain configuration
OPENBAS_HOST=${OPENBAS_HOST}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
EOF

# Write the Docker Compose file defining all services (OpenBAS, dependencies, Traefik)
cat > docker-compose.yml <<-'COMPOSE'
version: "3.9"

services:
  traefik:
    image: traefik:2.10
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false   # Only enable services we explicitly label
      - --providers.docker.network=${COMPOSE_PROJECT_NAME}_default
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesResolvers.le.acme.httpChallenge.entryPoint=web
      - --certificatesResolvers.le.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesResolvers.le.acme.storage=/etc/traefik/acme/acme.json
      - --api.dashboard=true            # (Optional) enable Traefik dashboard at /dashboard (you may secure this in production)
    ports:
      - "80:80"      # HTTP
      - "443:443"    # HTTPS
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik-data:/etc/traefik   # Stores ACME cert data (acme.json)
    restart: always

  pgsql:
    image: postgres:17-alpine
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: openbas
    volumes:
      - pgsqldata:/var/lib/postgresql/data   # Persistent storage for DB [oai_citation:9‡docs.openbas.io](https://docs.openbas.io/latest/deployment/installation/#:~:text=In%20the%20%60docker,persistent%20volumes%20for%20the%20dependencies)
    restart: always
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "${POSTGRES_USER}", "-d", "openbas"]
      interval: 10s
      timeout: 5s
      retries: 5

  minio:
    image: minio/minio:RELEASE.2024-05-28T17-19-04Z
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    command: server /data
    volumes:
      - s3data:/data                   # Persistent storage for MinIO (S3) [oai_citation:10‡docs.openbas.io](https://docs.openbas.io/latest/deployment/installation/#:~:text=In%20the%20%60docker,persistent%20volumes%20for%20the%20dependencies)
    ports:
      - "9000:9000"   # (Optional) expose MinIO console on localhost:9000
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 10s
      timeout: 5s
      retries: 5

  rabbitmq:
    image: rabbitmq:3.13-management
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_DEFAULT_USER}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_DEFAULT_PASS}
      RABBITMQ_NODENAME: rabbit01@localhost
    volumes:
      - amqpdata:/var/lib/rabbitmq    # Persistent storage for RabbitMQ queues [oai_citation:11‡docs.openbas.io](https://docs.openbas.io/latest/deployment/installation/#:~:text=In%20the%20%60docker,persistent%20volumes%20for%20the%20dependencies)
    restart: always
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes
    volumes:
      - redisdata:/data              # Persistent storage for Redis data (appendonly log)
    restart: always
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  elasticsearch:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.17.4
    environment:
      - discovery.type=single-node        # Single-node cluster mode
      - xpack.security.enabled=false      # Disable security for simplicity (no auth)
      - xpack.ml.enabled=false
      - thread_pool.search.queue_size=5000
      - logger.org.elasticsearch.discovery=ERROR
      - ES_JAVA_OPTS=-Xms4g -Xmx4g         # Memory allocation (adjust for your host)
    ulimits:
      memlock:                   # Allow elastic to lock memory (performance)
        soft: -1
        hard: -1
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - esdata:/usr/share/elasticsearch/data   # Persistent storage for Elasticsearch indices [oai_citation:12‡docs.openbas.io](https://docs.openbas.io/latest/deployment/installation/#:~:text=In%20the%20%60docker,persistent%20volumes%20for%20the%20dependencies)
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:9200/_cluster/health?wait_for_status=yellow&timeout=1s" ]
      interval: 30s
      timeout: 10s
      retries: 50

  openbas:
    image: openbas/platform:1.12.2          # OpenBAS core platform image (update tag to latest stable release)
    depends_on:
      - pgsql
      - rabbitmq
      - minio
      - elasticsearch
      - redis
    environment:
      # OpenBAS core configuration
      SERVER_SSL_KEY-STORE-PASSWORD: ${KEYSTORE_PASSWORD}
      OPENBAS_BASE-URL: http://${OPENBAS_HOST}   # Base URL where OpenBAS will be accessed (used for links generation)
      OPENBAS_AUTH-LOCAL-ENABLE: "true"          # Enable local (internal) auth
      OPENBAS_ADMIN_EMAIL: ${OPENBAS_ADMIN_EMAIL}
      OPENBAS_ADMIN_PASSWORD: ${OPENBAS_ADMIN_PASSWORD}
      OPENBAS_ADMIN_TOKEN: ${OPENBAS_ADMIN_TOKEN}
      # Database (PostgreSQL) settings
      SPRING_DATASOURCE_URL: jdbc:postgresql://pgsql:5432/openbas
      SPRING_DATASOURCE_USERNAME: ${POSTGRES_USER}
      SPRING_DATASOURCE_PASSWORD: ${POSTGRES_PASSWORD}
      # Message broker (RabbitMQ) settings
      OPENBAS_RABBITMQ-ADDRESSES: amqp://rabbitmq:5672
      OPENBAS_RABBITMQ-USER: ${RABBITMQ_DEFAULT_USER}
      OPENBAS_RABBITMQ-PASSWORD: ${RABBITMQ_DEFAULT_PASS}
      # Object storage (MinIO) settings
      OPENBAS_MINIO-ENDPOINT: http://minio:9000
      OPENBAS_MINIO-ACCESS-KEY: ${MINIO_ROOT_USER}
      OPENBAS_MINIO-SECRET-KEY: ${MINIO_ROOT_PASSWORD}
      OPENBAS_MINIO-BUCKET: obas              # Bucket name for OpenBAS to use in MinIO
      # Search engine (Elasticsearch) settings
      SPRING_ELASTICSEARCH_URIS: http://elasticsearch:9200
      # (Optional) Redis settings can be added if OpenBAS utilizes Redis (not required in current version)
      # Integration: (No direct OpenCTI config needed on OpenBAS side; OpenCTI will call OpenBAS API)
    labels:
      - traefik.enable=true
      - traefik.http.routers.openbas.rule=Host(`${OPENBAS_HOST}`)
      - traefik.http.routers.openbas.entrypoints=websecure
      - traefik.http.routers.openbas.tls=true
      - traefik.http.routers.openbas.tls.certresolver=le    # Use Let's Encrypt resolver for HTTPS
      - traefik.http.services.openbas.loadbalancer.server.port=8080
      # Optionally, also expose on HTTP (redirect to HTTPS or allow local testing):
      - traefik.http.routers.openbas-insecure.rule=Host(`${OPENBAS_HOST}`)
      - traefik.http.routers.openbas-insecure.entrypoints=web
      - traefik.http.routers.openbas-insecure.middlewares=traefik-http2https@docker
    restart: always
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/actuator/health"]
      interval: 30s
      timeout: 10s
      retries: 10

# Middleware for HTTP to HTTPS redirect (Traefik dynamic config via labels)
  traefik.http.middlewares.traefik-http2https.redirectscheme.scheme: https

volumes:
  pgsqldata:
  s3data:
  amqpdata:
  redisdata:
  esdata:
  traefik-data:
COMPOSE

# Launch the Docker Compose stack
echo "Starting OpenBAS stack with Docker Compose..."
docker compose -p openbas up -d

# Display initial credentials and integration info
echo "======================================================================"
echo "OpenBAS is deploying... (This may take a few minutes on first run)"
echo "Once all containers are healthy, access the OpenBAS UI via Traefik at:"
echo "   👉 URL: http://${OPENBAS_HOST}   (or https://${OPENBAS_HOST} if DNS is configured and certificate obtained)"
echo ""
echo "OpenBAS Admin Credentials:"
echo "   - Login Email:    ${OPENBAS_ADMIN_EMAIL}"
echo "   - Login Password: ${OPENBAS_ADMIN_PASSWORD}"
echo "   - API Token:      ${OPENBAS_ADMIN_TOKEN}"
echo ""
echo "🔗 To integrate with OpenCTI, configure your OpenCTI environment with:"
echo "      XTM__OPENBAS_URL=${OPENBAS_HOST}  (the OpenBAS base URL) [oai_citation:13‡github.com](https://github.com/OpenAEV-Platform/openaev/discussions/2006#:~:text=To%20integrate%20OpenCTI%20with%20OpenBAS%2C,refer%20to%20the%20documentation%20here)"
echo "      XTM__OPENBAS_TOKEN=${OPENBAS_ADMIN_TOKEN}  (the OpenBAS API token) [oai_citation:14‡github.com](https://github.com/OpenAEV-Platform/openaev/discussions/2006#:~:text=To%20integrate%20OpenCTI%20with%20OpenBAS%2C,refer%20to%20the%20documentation%20here)"
echo "  Then restart OpenCTI. This will enable the 'Simulate' button in OpenCTI to create scenarios in OpenBAS."
echo "======================================================================"