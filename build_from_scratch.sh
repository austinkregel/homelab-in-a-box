#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Dev OIDC seed values (skip setup wizard) ---
HOMELAB_INSTANCE_NAME="Homelab"
HOMELAB_BASE_DOMAIN="dionysis.kregel.host"
HOMELAB_OIDC_ISSUER="https://aut.hair"
HOMELAB_OIDC_CLIENT_ID="17"
HOMELAB_OIDC_CLIENT_SECRET="OtrRoAFu6DclcqsIDkEU8P3eJkpkGNs4EwDuSPs0"
HOMELAB_ORCHESTRATOR="docker_engine"
HOMELAB_GATEWAY="traefik"

NETWORK="homelab-internal"

echo "==> Tearing down existing homelab infrastructure..."
docker stop homelab homelab-postgres 2>/dev/null || true
docker rm homelab homelab-postgres 2>/dev/null || true

# Clean up managed and system containers before removing the network
docker ps -a --filter "label=homelab.managed=true" -q | xargs -r docker rm -f 2>/dev/null || true
docker ps -a --filter "label=homelab.system=true" -q | xargs -r docker rm -f 2>/dev/null || true

echo "==> Removing volumes..."
docker volume rm homelab-postgres-data homelab-secrets 2>/dev/null || true
docker volume ls --filter "name=homelab-" -q | xargs -r docker volume rm 2>/dev/null || true

echo "==> Removing network..."
docker network rm "${NETWORK}" 2>/dev/null || true

echo "==> Creating shared network..."
docker network create "${NETWORK}" 2>/dev/null || true

if [ "$MODE" = "prod" ]; then
  echo "==> Building production image..."
  docker build -t homelab-in-a-box:latest . --pull --no-cache

  echo "==> Starting homelab-in-a-box (prod)..."
  docker run -it --rm \
    --name homelab \
    --network "${NETWORK}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e HOMELAB_SEED_SETUP=true \
    -e HOMELAB_INSTANCE_NAME="${HOMELAB_INSTANCE_NAME}" \
    -e HOMELAB_BASE_DOMAIN="${HOMELAB_BASE_DOMAIN}" \
    -e HOMELAB_OIDC_ISSUER="${HOMELAB_OIDC_ISSUER}" \
    -e HOMELAB_OIDC_CLIENT_ID="${HOMELAB_OIDC_CLIENT_ID}" \
    -e HOMELAB_OIDC_CLIENT_SECRET="${HOMELAB_OIDC_CLIENT_SECRET}" \
    -e HOMELAB_ORCHESTRATOR="${HOMELAB_ORCHESTRATOR}" \
    -e HOMELAB_GATEWAY="${HOMELAB_GATEWAY}" \
    -p 4000:4000 \
    homelab-in-a-box:latest
else
  echo "==> Building dev image (deps only)..."
  docker build -t homelab-in-a-box:dev -f Dockerfile.dev .

  echo "==> Starting homelab-in-a-box (dev, source mounted)..."
  docker run -it --rm \
    --name homelab \
    --network "${NETWORK}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${SCRIPT_DIR}/lib:/app/lib" \
    -v "${SCRIPT_DIR}/config:/app/config" \
    -v "${SCRIPT_DIR}/priv:/app/priv" \
    -v "${SCRIPT_DIR}/assets:/app/assets" \
    -e HOMELAB_SEED_SETUP=true \
    -e HOMELAB_INSTANCE_NAME="${HOMELAB_INSTANCE_NAME}" \
    -e HOMELAB_BASE_DOMAIN="${HOMELAB_BASE_DOMAIN}" \
    -e HOMELAB_OIDC_ISSUER="${HOMELAB_OIDC_ISSUER}" \
    -e HOMELAB_OIDC_CLIENT_ID="${HOMELAB_OIDC_CLIENT_ID}" \
    -e HOMELAB_OIDC_CLIENT_SECRET="${HOMELAB_OIDC_CLIENT_SECRET}" \
    -e HOMELAB_ORCHESTRATOR="${HOMELAB_ORCHESTRATOR}" \
    -e HOMELAB_GATEWAY="${HOMELAB_GATEWAY}" \
    -p 4000:4000 \
    homelab-in-a-box:dev
fi
