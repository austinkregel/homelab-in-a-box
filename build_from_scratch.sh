#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load secrets / overrides from a gitignored .env (copy .env.example -> .env).
# Values already present in the environment take precedence over the file.
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/.env"
  set +a
fi

# --- Seed values (skip setup wizard) ---
# Non-secret defaults live here; override any of them via .env or the environment.
HOMELAB_INSTANCE_NAME="${HOMELAB_INSTANCE_NAME:-Homelab}"
HOMELAB_BASE_DOMAIN="${HOMELAB_BASE_DOMAIN:-dionysis.kregel.host}"
HOMELAB_OIDC_ISSUER="${HOMELAB_OIDC_ISSUER:-https://aut.hair}"
HOMELAB_OIDC_CLIENT_ID="${HOMELAB_OIDC_CLIENT_ID:-17}"
# The OIDC client secret has NO default: it must come from .env or the environment.
HOMELAB_OIDC_CLIENT_SECRET="${HOMELAB_OIDC_CLIENT_SECRET:-}"
HOMELAB_ORCHESTRATOR="${HOMELAB_ORCHESTRATOR:-docker_engine}"
HOMELAB_GATEWAY="${HOMELAB_GATEWAY:-traefik}"

if [ -z "${HOMELAB_OIDC_CLIENT_SECRET}" ]; then
  echo "WARNING: HOMELAB_OIDC_CLIENT_SECRET is empty — OIDC login will fail." >&2
  echo "         Copy .env.example to .env and set it (and rotate the old secret)." >&2
fi

NETWORK="homelab-internal"

echo "==> Tearing down existing homelab infrastructure..."
docker stop homelab homelab-iab-postgres homelab-iab-oban-postgres 2>/dev/null || true
docker rm homelab homelab-iab-postgres homelab-iab-oban-postgres 2>/dev/null || true

# Clean up managed and system containers before removing the network
docker ps -a --filter "label=homelab.managed=true" -q | xargs -r docker rm -f 2>/dev/null || true
docker ps -a --filter "label=homelab.system=true" -q | xargs -r docker rm -f 2>/dev/null || true

echo "==> Removing volumes..."
docker volume rm homelab-iab-postgres-data homelab-iab-oban-postgres-data homelab-iab-secrets 2>/dev/null || true
docker volume ls --filter "name=homelab-" -q | xargs -r docker volume rm 2>/dev/null || true

echo "==> Removing network..."
docker network rm "${NETWORK}" 2>/dev/null || true

echo "==> Creating shared network..."
docker network create "${NETWORK}" 2>/dev/null || true

if [ "$MODE" = "prod" ]; then
  echo "==> Building production image..."
  docker build -t homelab-in-a-box:latest . --pull --no-cache

  echo "==> Starting homelab-in-a-box (prod, detached)..."
  docker run -d \
    --name homelab \
    --restart unless-stopped \
    --memory "${HOMELAB_MEMORY_LIMIT:-1g}" \
    --cpus "${HOMELAB_CPU_LIMIT:-2}" \
    --network "${NETWORK}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v homelab-iab-secrets:/run/secrets \
    -e HOMELAB_SEED_SETUP=true \
    -e HOMELAB_INSTANCE_NAME="${HOMELAB_INSTANCE_NAME}" \
    -e HOMELAB_BASE_DOMAIN="${HOMELAB_BASE_DOMAIN}" \
    -e HOMELAB_OIDC_ISSUER="${HOMELAB_OIDC_ISSUER}" \
    -e HOMELAB_OIDC_CLIENT_ID="${HOMELAB_OIDC_CLIENT_ID}" \
    -e HOMELAB_OIDC_CLIENT_SECRET="${HOMELAB_OIDC_CLIENT_SECRET}" \
    -e HOMELAB_ORCHESTRATOR="${HOMELAB_ORCHESTRATOR}" \
    -e HOMELAB_GATEWAY="${HOMELAB_GATEWAY}" \
    -e PHX_HOST="${HOMELAB_BASE_DOMAIN}" \
    -e PHX_SCHEME="https" \
    -e PHX_PORT="443" \
    -p 4000:4000 \
    homelab-in-a-box:latest

  echo "==> Started. Follow logs with: docker logs -f homelab"
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
    -e PHX_HOST="${HOMELAB_BASE_DOMAIN}" \
    -e PHX_SCHEME="https" \
    -e PHX_PORT="443" \
    -e HOMELAB_GATEWAY="${HOMELAB_GATEWAY}" \
    -p 4000:4000 \
    homelab-in-a-box:dev
fi
