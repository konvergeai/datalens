#!/usr/bin/env bash
set -euo pipefail

# ----- Logging -----
LOG_DIR="/opt/datalens/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $msg" | tee -a "$LOG_FILE"
}
trap 'log "Script failed at line $LINENO."' ERR

log "Script started."

# ----- Input Arguments -----
VM_NAME="${1:?vm name required}"
ADMIN_USERNAME="${2:?admin username required}"
REACT_APP_GOOGLE_CLIENT="${3:?google client required}"
REACT_APP_ONEDRIVE_CLIENT_ID="${4:-}"
REACT_APP_ONEDRIVE_AUTHORITY="${5:-}"
REACT_APP_ONEDRIVE_REDIRECT_URI="${6:-}"
OPENAI_API_KEY="${7:?openai api key required}"
GPT_MODEL="${8:?gpt model required}"
JWT_SECRET_KEY="${9:?jwt secret key required}"
CONTAINER_BLOB_BASE_URL="${10:?container blob base url required}"
ACR_USERNAME="${11:?acr username required}"
ACR_PASSWORD="${12:-}"

log "Parsed script arguments."

# ----- Install Prerequisites -----
log "Updating apt and enabling universe repository..."
apt-get update -qq >> "$LOG_FILE" 2>&1
add-apt-repository -y universe >> "$LOG_FILE" 2>&1 || true
apt-get update -qq >> "$LOG_FILE" 2>&1

log "Installing prerequisites: ca-certificates, curl, apt-transport-https, lsb-release, gnupg, jq, openssl, software-properties-common..."
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    apt-transport-https \
    lsb-release \
    gnupg \
    jq \
    openssl \
    software-properties-common >> "$LOG_FILE" 2>&1

if ! command -v jq >/dev/null 2>&1; then
    log "ERROR: jq not installed!"
    exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
    log "ERROR: curl not installed!"
    exit 2
fi

log "All required CLI tools present."

# ----- Fetch Public IP -----
log "Fetching VM public IP..."
PUBLIC_IP=$(curl -s -H Metadata:true \
    "http://169.254.169.254/metadata/instance/network/interface?api-version=2021-02-01&format=json" \
    | jq -r '.[0].ipv4.ipAddress[0].publicIpAddress')
if [[ -z "$PUBLIC_IP" || "$PUBLIC_IP" == "null" ]]; then
    log "ERROR: Could not retrieve public IP address from metadata service."
    exit 1
fi
log "Public IP is $PUBLIC_IP"

REACT_APP_API="http://$PUBLIC_IP/api/v1/"
REACT_APP_BASEURL="http://$PUBLIC_IP/"

# ----- Generate Backend Service Secrets -----
POSTGRES_USER="postgres"
POSTGRES_PASSWORD=$(openssl rand -hex 16)
POSTGRES_DB="postgres"
POSTGRES_HOST="postgres"
POSTGRES_PORT="5432"

RABBITMQ_USER="guest"
RABBITMQ_PASS="guest"
RABBITMQ_HOST="rabbitmq"
RABBITMQ_PORT="5672"

ELASTICSEARCH_USER="elastic"
ELASTICSEARCH_PASSWORD=$(openssl rand -hex 16)
ELASTICSEARCH_HOST="elasticsearch"
ELASTICSEARCH_PORT="9200"

ALGORITHM="HS256"
CELERY_BROKER="amqp://$RABBITMQ_USER:$RABBITMQ_PASS@$RABBITMQ_HOST:$RABBITMQ_PORT//"
CELERY_BACKEND="db+postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB"

log "Generated backend service secrets."

# ----- Install Azure CLI -----
log "Installing Azure CLI..."
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | tee /etc/apt/sources.list.d/azure-cli.list
apt-get update -qq >> "$LOG_FILE" 2>&1
apt-get install -y --no-install-recommends azure-cli >> "$LOG_FILE" 2>&1

# ----- Install Docker -----
log "Installing Docker Engine & CLI..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor | tee /etc/apt/keyrings/docker.gpg > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq >> "$LOG_FILE" 2>&1
apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

# Add admin user to docker group
log "Adding $ADMIN_USERNAME to docker group..."
usermod -aG docker "$ADMIN_USERNAME" >> "$LOG_FILE" 2>&1 || log "usermod failed (may not be fatal)."

# Clean up apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*
log "System packages installed and cleaned up."

# ----- Prepare Directories -----
OUT_DIR="/opt/datalens"
mkdir -p "$OUT_DIR"
log "Created $OUT_DIR directory."

# ----- Write .env File -----
ENV_FILE="$OUT_DIR/.env"
: > "$ENV_FILE"
{
  echo "ALGORITHM=$ALGORITHM"
  echo "CELERY_BACKEND=$CELERY_BACKEND"
  echo "CELERY_BROKER=$CELERY_BROKER"
  echo "ELASTICSEARCH_HOST=$ELASTICSEARCH_HOST"
  echo "ELASTICSEARCH_PASSWORD=$ELASTICSEARCH_PASSWORD"
  echo "ELASTICSEARCH_PORT=$ELASTICSEARCH_PORT"
  echo "ELASTICSEARCH_USER=$ELASTICSEARCH_USER"
  echo "GPT_MODEL=$GPT_MODEL"
  echo "JWT_SECRET_KEY=$JWT_SECRET_KEY"
  echo "OPENAI_API_KEY=$OPENAI_API_KEY"
  echo "POSTGRES_DB=$POSTGRES_DB"
  echo "POSTGRES_HOST=$POSTGRES_HOST"
  echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
  echo "POSTGRES_PORT=$POSTGRES_PORT"
  echo "POSTGRES_USER=$POSTGRES_USER"
  echo "RABBITMQ_HOST=$RABBITMQ_HOST"
  echo "RABBITMQ_PASS=$RABBITMQ_PASS"
  echo "RABBITMQ_PORT=$RABBITMQ_PORT"
  echo "RABBITMQ_USER=$RABBITMQ_USER"
  echo "REACT_APP_API=$REACT_APP_API"
  echo "REACT_APP_BASEURL=$REACT_APP_BASEURL"
  echo "REACT_APP_GOOGLE_CLIENT=$REACT_APP_GOOGLE_CLIENT"
  echo "REACT_APP_ONEDRIVE_AUTHORITY=$REACT_APP_ONEDRIVE_AUTHORITY"
  echo "REACT_APP_ONEDRIVE_CLIENT_ID=$REACT_APP_ONEDRIVE_CLIENT_ID"
  echo "REACT_APP_ONEDRIVE_REDIRECT_URI=$REACT_APP_ONEDRIVE_REDIRECT_URI"
} >> "$ENV_FILE"
log "Wrote environment variables to $ENV_FILE."

# ----- Docker Network -----
if ! docker network ls --filter name=^datalens-network$ --format '{{.Name}}' | grep -q '^datalens-network$'; then
  docker network create datalens-network >> "$LOG_FILE" 2>&1
  log "Created Docker network datalens-network."
else
  log "Docker network datalens-network already exists."
fi

# ----- Host Directories for Mounts -----
mkdir -p /opt/datalens/data/pdf \
         /opt/datalens/data/txt \
         /opt/datalens/data/csv \
         /opt/datalens/data/vectorstore \
         /opt/datalens/frontend_images
log "Prepared bind-mount directories."

# ----- Download & Load Docker Images -----
ARTIFACT_DIR="/opt/datalens/artifacts"
mkdir -p "$ARTIFACT_DIR"
BASE="${CONTAINER_BLOB_BASE_URL%/}"
log "Downloading images from $BASE..."
for image in backend-datalens-api backend-datalens-ui frontend-react-app-dev nginx-reverse-proxy; do
    TAR_PATH="$ARTIFACT_DIR/${image}.tar"
    log "Downloading $image..."
    curl -sL "$BASE/${image}.tar" -o "$TAR_PATH"
    log "Loading $image into Docker..."
    docker load -i "$TAR_PATH" >> "$LOG_FILE" 2>&1
done
rm -f "$ARTIFACT_DIR"/*.tar

# ----- Start/Restart Core Containers (Postgres, RabbitMQ, Elasticsearch) -----
# [Container startup blocks: same as before, not repeated for brevity—keep yours as-is]

# For example, Postgres:
if docker ps -aq -f name=^postgres$ | grep -q .; then
  docker rm -f postgres >> "$LOG_FILE" 2>&1
  log "Removed existing postgres container."
fi
docker run -d --name postgres --network datalens-network -p 5431:5432 \
  -v postgres_data:/var/lib/postgresql/data \
  --env-file "$ENV_FILE" \
  --health-cmd 'pg_isready -U $${POSTGRES_USER}' --health-interval 10s \
  --health-timeout 5s --health-retries 5 \
  postgres:latest >> "$LOG_FILE" 2>&1
log "Started Postgres container."

# (Do the same for RabbitMQ, Elasticsearch, datalens-api, datalens-ui, react-app-dev, nginx-reverse-proxy as in your previous script.)

# ----- Certs and NGINX Setup -----
NGINX_CERT_DIR="/etc/nginx/certs"
mkdir -p "$NGINX_CERT_DIR"
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout "$NGINX_CERT_DIR/nginx.key" \
  -out "$NGINX_CERT_DIR/nginx.crt" \
  -subj "/CN=$(hostname)" >> "$LOG_FILE" 2>&1
chmod 600 "$NGINX_CERT_DIR/"*.key

NGINX_CONF_DIR="/opt/datalens/nginx"
mkdir -p "$NGINX_CONF_DIR"
cat <<'EOF' > "$NGINX_CONF_DIR/nginx.conf"
# (Your nginx configuration here)
EOF

if docker ps -aq -f name=^reverse-proxy$ | grep -q .; then
  docker rm -f reverse-proxy >> "$LOG_FILE" 2>&1
  log "Removed existing reverse-proxy container."
fi
docker run -d --name reverse-proxy --network datalens-network -p 80:80 -p 443:443 \
  -v /etc/nginx/certs:/etc/nginx/certs:ro \
  datalens.azurecr.io/nginx-reverse-proxy:latest >> "$LOG_FILE" 2>&1
log "Started nginx reverse-proxy container."

log "DataLens provisioning script completed successfully."
