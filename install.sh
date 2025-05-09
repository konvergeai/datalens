#!/usr/bin/env bash
set -euo pipefail

# 1. Install prerequisites
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    apt-transport-https \
    lsb-release \
    gnupg \
    jq

# 2. Import Microsoft GPG key and add Azure CLI repo
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
  | gpg --dearmor \
  | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null

AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" \
  | tee /etc/apt/sources.list.d/azure-cli.list

# 3. Install the Azure CLI
apt-get update -qq
apt-get install -y --no-install-recommends azure-cli

# 4. Install Docker Engine & CLI plugins
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor \
  | tee /etc/apt/keyrings/docker.gpg > /dev/null

echo \
  "deb [arch=$(dpkg --print-architecture) \
        signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# 5. Add the VM user to the docker group to access the Docker socket
usermod -aG docker ubuntu-user

# 6. Login to Azure using the VM’s managed identity
az login --identity

# 7. Perform an ACR login
az acr login --name datalens

# 8. (Optional) Clean up APT caches to save space
apt-get clean
rm -rf /var/lib/apt/lists/*

# 9. Your custom extension message
echo "Hello from Azure Extensions!" > /var/log/azure-extensions-message.txt

# 10. Pull secrets from Key Vault and generate .env inside datalens directory
VAULT="datalensvm-kv8a4f9b"
OUT_DIR="/opt/datalens"
OUT_FILE="$OUT_DIR/.env"

mkdir -p "$OUT_DIR"
: > "$OUT_FILE"

echo "Fetching VM public IP..."
PUBLIC_IP=$(curl -s -H Metadata:true \
  "http://169.254.169.254/metadata/instance/network/interface?api-version=2021-02-01&format=json" \
  | jq -r '.[0].ipv4.ipAddress[0].publicIpAddress')
echo "→ Public IP is $PUBLIC_IP"

echo "Building .env from Key Vault secrets..."
az keyvault secret list --vault-name "$VAULT" --query "[].name" -o tsv | \
while read -r name; do
    val=$(az keyvault secret show \
            --vault-name="$VAULT" \
            --name="$name" \
            --query value -o tsv)

    if [[ "$val" == *"change.me"* ]]; then
      echo "  • Replacing placeholder in $name"
      val="${val//change.me/$PUBLIC_IP}"
    fi

    var=$(echo "$name" | tr '[:lower:]-' '[:upper:]_')
    printf '%s=%s\n' "$var" "$val" >> "$OUT_FILE"
done

echo "→ Wrote $(wc -l < "$OUT_FILE") vars to $OUT_FILE"

# 11. Ensure the 'datalens-network' external network exists
if ! docker network ls --filter name=^datalens-network$ --format '{{.Name}}' | grep -q '^datalens-network$'; then
  docker network create datalens-network
fi

# 12. Cleanup and start the Postgres container
#    Uses secrets from /opt/datalens/.env for POSTGRES_* variables
if docker ps -aq -f name=^postgres$ | grep -q .; then
  docker rm -f postgres
fi

docker run -d \
  --name postgres \
  --network datalens-network \
  -p 5431:5432 \
  -v postgres_data:/var/lib/postgresql/data \
  --env-file /opt/datalens/.env \
  --health-cmd 'pg_isready -U $${POSTGRES_USER}' \
  --health-interval 10s \
  --health-timeout 5s \
  --health-retries 5 \
  postgres:latest

# 13. Cleanup and start the RabbitMQ container
#    Provides AMQP port 5672 and management UI on 15672
#    Uses built-in healthcheck via rabbitmqctl status
if docker ps -aq -f name=^rabbitmq$ | grep -q .; then
  docker rm -f rabbitmq
fi

docker run -d \
  --name rabbitmq \
  --network datalens-network \
  -p 5672:5672 \
  -p 15672:15672 \
  --health-cmd 'rabbitmqctl status' \
  --health-interval 10s \
  --health-timeout 5s \
  --health-retries 5 \
  rabbitmq:management

# 14. Cleanup and start the Elasticsearch container
#    Single-node discovery with security and JVM options
if docker ps -aq -f name=^elasticsearch$ | grep -q .; then
  docker rm -f elasticsearch
fi

docker run -d \
  --name elasticsearch \
  --network datalens-network \
  -p 9200:9200 \
  -p 9300:9300 \
  -v elasticsearch_data:/usr/share/elasticsearch/data \
  --env-file /opt/datalens/.env \
  --env discovery.type=single-node \
  --env 'ES_JAVA_OPTS=-Xms512m -Xmx512m' \
  --health-cmd 'curl -f http://localhost:9200' \
  --health-interval 10s \
  --health-timeout 5s \
  --health-retries 5 \
  docker.elastic.co/elasticsearch/elasticsearch-oss:7.10.2

# 15. Prepare host bind-mount directories for DataLens API & UI
mkdir -p /opt/datalens/data/pdf \
         /opt/datalens/data/txt \
         /opt/datalens/data/csv \
         /opt/datalens/data/vectorstore \
         /opt/datalens/frontend_images

# 16. Pull and start the DataLens API container
docker pull datalens.azurecr.io/backend-datalens-api:latest

if docker ps -aq -f name=^datalens-api$ | grep -q .; then
  docker rm -f datalens-api
fi
docker run -d \
  --name datalens-api \
  --network datalens-network \
  -p 8000:8000 \
  -v /opt/datalens/data:/app/data \
  --env-file /opt/datalens/.env \
  datalens.azurecr.io/backend-datalens-api:latest

# 17. Pull and start the DataLens UI container
docker pull datalens.azurecr.io/backend-datalens-ui:latest

if docker ps -aq -f name=^datalens-ui$ | grep -q .; then
  docker rm -f datalens-ui
fi
docker run -d \
  --name datalens-ui \
  --network datalens-network \
  -p 8501:8501 \
  -v /opt/datalens/data/pdf:/app/data/pdf \
  -v /opt/datalens/data/txt:/app/data/txt \
  -v /opt/datalens/data/csv:/app/data/csv \
  -v /opt/datalens/data/vectorstore:/app/data/vectorstore \
  --env-file /opt/datalens/.env \
  datalens.azurecr.io/backend-datalens-ui:latest

# 18. Pull and start the DataLens Frontend container
docker pull datalens.azurecr.io/frontend-react-app-dev:latest

if docker ps -aq -f name=^react-app-dev$ | grep -q .; then
  docker rm -f react-app-dev
fi

docker run -d \
  --name react-app-dev \
  --network datalens-network \
  -p 3000:3000 \
  -v react-app-dev-node_modules:/frontend/node_modules\
  --env-file /opt/datalens/.env \
  -e NODE_ENV=development \
  -e CHOKIDAR_USEPOLLING=true \
  datalens.azurecr.io/frontend-react-app-dev:latest

# 19. Generate certs
NGINX_CERT_DIR="/etc/nginx/certs"
mkdir -p "$NGINX_CERT_DIR"
openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout "$NGINX_CERT_DIR/nginx.key" \
  -out    "$NGINX_CERT_DIR/nginx.crt" \
  -subj "/CN=$(hostname)"
chmod 600 "$NGINX_CERT_DIR/"*.key

# Write nginx.conf
NGINX_CONF_DIR="/opt/datalens/nginx"
mkdir -p "$NGINX_CONF_DIR"
cat <<'EOF' > "$NGINX_CONF_DIR/nginx.conf"
...  # (the config from step 2)
EOF

# 20. Pull and start the nginx reverse-proxy container
docker pull datalens.azurecr.io/nginx-reverse-proxy:latest

if docker ps -aq -f name=^reverse-proxy$ | grep -q .; then
  docker rm -f reverse-proxy
fi

docker run -d \
  --name reverse-proxy \
  --network datalens-network \
  -p 80:80 \
  -p 443:443 \
  -v /etc/nginx/certs:/etc/nginx/certs:ro \
  datalens.azurecr.io/nginx-reverse-proxy:latest
