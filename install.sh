#!/usr/bin/env bash
set -euo pipefail

# Setup log directory and file
LOG_DIR="/opt/datalens/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install.log"

log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $msg" | tee -a "$LOG_FILE"
}

trap 'log "Script failed at line $LINENO."' ERR

log "Script started."

# Input arguments
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

# Generate backend service secrets
POSTGRES_USER="postgres"
POSTGRES_PASSWORD=$(openssl rand -hex 16)
POSTGRES_DB="postgres"
POSTGRES_HOST="localhost"
POSTGRES_PORT="5432"

RABBITMQ_USER="guest"
RABBITMQ_PASS="guest"
RABBITMQ_HOST="localhost"
RABBITMQ_PORT="5672"

ELASTICSEARCH_USER="elastic"
ELASTICSEARCH_PASSWORD=$(openssl rand -hex 16)
ELASTICSEARCH_HOST="localhost"
ELASTICSEARCH_PORT="9200"

log "Generated service credentials."

# Install prerequisites
log "Updating APT and installing prerequisites..."
apt-get update -qq >> "$LOG_FILE" 2>&1
apt-get install -y --no-install-recommends \
    ca-certificates curl apt-transport-https lsb-release gnupg jq >> "$LOG_FILE" 2>&1

# Install Azure CLI
log "Installing Azure CLI..."
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | tee /etc/apt/sources.list.d/azure-cli.list
apt-get update -qq >> "$LOG_FILE" 2>&1
apt-get install -y --no-install-recommends azure-cli >> "$LOG_FILE" 2>&1

# Install Docker Engine & CLI
log "Installing Docker Engine..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor | tee /etc/apt/keyrings/docker.gpg > /dev/null
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq >> "$LOG_FILE" 2>&1
apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1

# Add user to docker group
log "Adding $ADMIN_USERNAME to docker group..."
usermod -aG docker "$ADMIN_USERNAME" >> "$LOG_FILE" 2>&1 || log "usermod failed (may not be fatal)."

# Clean up APT caches
apt-get clean
rm -rf /var/lib/apt/lists/*
log "System packages installed."

# Prepare directories
OUT_DIR="/opt/datalens"
mkdir -p "$OUT_DIR"
log "Created $OUT_DIR directory."

# Build .env file
ENV_FILE="$OUT_DIR/.env"
: > "$ENV_FILE"

{
  echo "REACT_APP_GOOGLE_CLIENT=$REACT_APP_GOOGLE_CLIENT"
  echo "REACT_APP_ONEDRIVE_CLIENT_ID=$REACT_APP_ONEDRIVE_CLIENT_ID"
  echo "REACT_APP_ONEDRIVE_AUTHORITY=$REACT_APP_ONEDRIVE_AUTHORITY"
  echo "REACT_APP_ONEDRIVE_REDIRECT_URI=$REACT_APP_ONEDRIVE_REDIRECT_URI"
  echo "OPENAI_API_KEY=$OPENAI_API_KEY"
  echo "GPT_MODEL=$GPT_MODEL"
  echo "JWT_SECRET_KEY=$JWT_SECRET_KEY"
  echo "POSTGRES_USER=$POSTGRES_USER"
  echo "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
  echo "POSTGRES_DB=$POSTGRES_DB"
  echo "POSTGRES_HOST=$POSTGRES_HOST"
  echo "POSTGRES_PORT=$POSTGRES_PORT"
  echo "RABBITMQ_USER=$RABBITMQ_USER"
  echo "RABBITMQ_PASS=$RABBITMQ_PASS"
  echo "RABBITMQ_HOST=$RABBITMQ_HOST"
  echo "RABBITMQ_PORT=$RABBITMQ_PORT"
  echo "ELASTICSEARCH_USER=$ELASTICSEARCH_USER"
  echo "ELASTICSEARCH_PASSWORD=$ELASTICSEARCH_PASSWORD"
  echo "ELASTICSEARCH_HOST=$ELASTICSEARCH_HOST"
  echo "ELASTICSEARCH_PORT=$ELASTICSEARCH_PORT"
} >> "$ENV_FILE"

log "Wrote environment variables to $ENV_FILE."

# Create Docker network
if ! docker network ls --filter name=^datalens-network$ --format '{{.Name}}' | grep -q '^datalens-network$'; then
  docker network create datalens-network >> "$LOG_FILE" 2>&1
  log "Created Docker network datalens-network."
else
  log "Docker network datalens-network already exists."
fi

# Prepare host bind-mount directories
mkdir -p /opt/datalens/data/pdf \
         /opt/datalens/data/txt \
         /opt/datalens/data/csv \
         /opt/datalens/data/vectorstore \
         /opt/datalens/frontend_images
log "Prepared bind-mount directories."

# Download & load Docker images from Blob Storage
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

# Start Postgres container
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

# Start RabbitMQ container
if docker ps -aq -f name=^rabbitmq$ | grep -q .; then
  docker rm -f rabbitmq >> "$LOG_FILE" 2>&1
  log "Removed existing rabbitmq container."
fi
docker run -d --name rabbitmq --network datalens-network -p 5672:5672 -p 15672:15672 \
  --health-cmd 'rabbitmqctl status' --health-interval 10s \
  --health-timeout 5s --health-retries 5 \
  rabbitmq:management >> "$LOG_FILE" 2>&1
log "Started RabbitMQ container."

# Start Elasticsearch container
if docker ps -aq -f name=^elasticsearch$ | grep -q .; then
  docker rm -f elasticsearch >> "$LOG_FILE" 2>&1
  log "Removed existing elasticsearch container."
fi
docker run -d --name elasticsearch --network datalens-network -p 9200:9200 -p 9300:9300 \
  -v elasticsearch_data:/usr/share/elasticsearch/data \
  --env-file "$ENV_FILE" \
  --env discovery.type=single-node \
  --env 'ES_JAVA_OPTS=-Xms512m -Xmx512m' \
  --health-cmd 'curl -f http://localhost:9200' --health-interval 10s \
  --health-timeout 5s --health-retries 5 \
  docker.elastic.co/elasticsearch/elasticsearch-oss:7.10.2 >> "$LOG_FILE" 2>&1
log "Started Elasticsearch container."

# Start DataLens API container
if docker ps -aq -f name=^datalens-api$ | grep -q .; then
  docker rm -f datalens-api >> "$LOG_FILE" 2>&1
  log "Removed existing datalens-api container."
fi
docker run -d --name datalens-api --network datalens-network -p 8000:8000 \
  -v /opt/datalens/data:/app/data \
  --env-file "$ENV_FILE" \
  datalens.azurecr.io/backend-datalens-api:latest >> "$LOG_FILE" 2>&1
log "Started DataLens API container."

# Start DataLens UI container
if docker ps -aq -f name=^datalens-ui$ | grep -q .; then
  docker rm -f datalens-ui >> "$LOG_FILE" 2>&1
  log "Removed existing datalens-ui container."
fi
docker run -d --name datalens-ui --network datalens-network -p 8501:8501 \
  -v /opt/datalens/data/pdf:/app/data/pdf \
  -v /opt/datalens/data/txt:/app/data/txt \
  -v /opt/datalens/data/csv:/app/data/csv \
  -v /opt/datalens/data/vectorstore:/app/data/vectorstore \
  --env-file "$ENV_FILE" \
  datalens.azurecr.io/backend-datalens-ui:latest >> "$LOG_FILE" 2>&1
log "Started DataLens UI container."

# Start DataLens Frontend container
if docker ps -aq -f name=^react-app-dev$ | grep -q .; then
  docker rm -f react-app-dev >> "$LOG_FILE" 2>&1
  log "Removed existing react-app-dev container."
fi
docker run -d --name react-app-dev --network datalens-network -p 3000:3000 \
  -v react-app-dev-node_modules:/frontend/node_modules \
  --env-file "$ENV_FILE" \
  -e NODE_ENV=development \
  -e CHOKIDAR_USEPOLLING=true \
  datalens.azurecr.io/frontend-react-app-dev:latest >> "$LOG_FILE" 2>&1
log "Started DataLens Frontend container."

# Start nginx reverse-proxy container
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
