#!/bin/bash

BASE_DIR="./"

if [ ! -f "$BASE_DIR/.env" ]; then
  echo "Error: .env file not found! Please create .env with required variables (ELASTICSEARCH_PORT, KIBANA_PORT, LOGSTASH_PORT, ELASTIC_PASSWORD)."
  exit 1
fi

set -a
source "$BASE_DIR/.env"
set +a

if [ -z "$ELASTIC_PASSWORD" ]; then
  echo "Error: ELASTIC_PASSWORD not defined in .env!"
  exit 1
fi

echo "Cleaning up old volumes..."
docker-compose -f "$BASE_DIR/docker-compose.yml" down -v
docker volume rm elk_es_data elk_kibana_data 2>/dev/null

echo "Creating nginx.log..."
cat <<LOG > "$BASE_DIR/logstash/nginx.log"
{"message": "Test log entry", "remote_ip": "8.8.8.8", "agent": "Mozilla/5.0"}
LOG
chmod 644 "$BASE_DIR/logstash/nginx.log"

echo "Creating .secrets file..."
cat <<SECRETS > "$BASE_DIR/.secrets"
ELASTIC_PASSWORD=${ELASTIC_PASSWORD}
KIBANA_SERVICE_TOKEN=
LOGSTASH_SERVICE_TOKEN=
SECRETS
chmod 600 "$BASE_DIR/.secrets"

echo "Starting Elasticsearch..."
docker-compose -f "$BASE_DIR/docker-compose.yml" up -d elasticsearch

echo "Waiting for Elasticsearch to be healthy..."
until curl -s -u "elastic:$ELASTIC_PASSWORD" "http://localhost:$ELASTICSEARCH_PORT/_cluster/health" | grep -q '"status":"green"\|"status":"yellow"'; do
  sleep 5
  echo "Still waiting for Elasticsearch..."
done

echo "Ensuring elastic user password..."
curl -s -u "elastic:$ELASTIC_PASSWORD" -X POST "http://localhost:$ELASTICSEARCH_PORT/_security/user/elastic/_password" -H "Content-Type: application/json" -d "{\"password\": \"$ELASTIC_PASSWORD\"}" || {
  echo "Failed to set elastic password!"
  exit 1
}

echo "Generating service tokens..."
KIBANA_TOKEN=$(curl -s -u "elastic:$ELASTIC_PASSWORD" -X POST "http://localhost:$ELASTICSEARCH_PORT/_security/service/elastic/kibana/credential/token" -H "Content-Type: application/json" | jq -r '.value')

LOGSTASH_TOKEN=$(curl -s -u "elastic:$ELASTIC_PASSWORD" -X POST "http://localhost:$ELASTICSEARCH_PORT/_security/service/elastic/logstash/credential/token" -H "Content-Type: application/json" | jq -r '.value')

echo "Updating .secrets with service tokens..."
echo "KIBANA_SERVICE_TOKEN=$KIBANA_TOKEN" >> "$BASE_DIR/.secrets"
echo "LOGSTASH_SERVICE_TOKEN=$LOGSTASH_TOKEN" >> "$BASE_DIR/.secrets"

echo "Stopping temporary Elasticsearch..."
docker-compose -f "$BASE_DIR/docker-compose.yml" down

echo "Starting all services..."
docker-compose -f "$BASE_DIR/docker-compose.yml" up -d

echo "Setup complete! Check container status with 'docker ps'"
