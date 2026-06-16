#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-dev}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Dev OIDC seed values (skip setup wizard) ---
# Load from .env if present (see .env.example). Never commit real secrets.
if [ -f "${SCRIPT_DIR}/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

HOMELAB_INSTANCE_NAME="${HOMELAB_INSTANCE_NAME:-Homelab}"
HOMELAB_BASE_DOMAIN="${HOMELAB_BASE_DOMAIN:-homelab.local}"
HOMELAB_OIDC_ISSUER="${HOMELAB_OIDC_ISSUER:-https://aut.hair}"
HOMELAB_OIDC_CLIENT_ID="${HOMELAB_OIDC_CLIENT_ID:-}"
HOMELAB_OIDC_CLIENT_SECRET="${HOMELAB_OIDC_CLIENT_SECRET:-}"
HOMELAB_ORCHESTRATOR="${HOMELAB_ORCHESTRATOR:-docker_engine}"
HOMELAB_GATEWAY="${HOMELAB_GATEWAY:-traefik}"

if [ -z "${HOMELAB_OIDC_CLIENT_ID}" ] || [ -z "${HOMELAB_OIDC_CLIENT_SECRET}" ]; then
  echo "==> Error: HOMELAB_OIDC_CLIENT_ID and HOMELAB_OIDC_CLIENT_SECRET must be set." >&2
  echo "    Copy .env.example to .env and fill in your OIDC values." >&2
  exit 1
fi

NETWORK="homelab-internal"

# Host-side ZFS agent (decision §1). The BEAM container talks to zfs/zpool only
# through this socket — never /dev/zfs or zfsutils inside the image.
ZFS_AGENT_SOCKET="${ZFS_AGENT_SOCKET:-/run/homelab/zfs.sock}"
ZFS_AGENT_RUN_DIR="$(dirname "${ZFS_AGENT_SOCKET}")"

# Extra docker run flags when the agent socket exists on the host.
docker_zfs_agent_mounts() {
  if [ -S "${ZFS_AGENT_SOCKET}" ]; then
    printf '%s\n' \
      "-v ${ZFS_AGENT_RUN_DIR}:${ZFS_AGENT_RUN_DIR}" \
      "-e HOMELAB_ZFS_AGENT_SOCKET=${ZFS_AGENT_SOCKET}"
  else
    {
      echo "==> Warning: ${ZFS_AGENT_SOCKET} not found."
      echo "    Storage features (pools, datasets, snapshots) will return :agent_unavailable"
      echo "    until homelab-zfs-agent is installed and running on the host."
      echo "    Container orchestration and the rest of the UI still work without it."
    } >&2
  fi
}

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
  # shellcheck disable=SC2046
  docker run -it --rm \
    --name homelab \
    --network "${NETWORK}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    $(docker_zfs_agent_mounts) \
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
  # shellcheck disable=SC2046
  docker run -it --rm \
    --name homelab \
    --network "${NETWORK}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    $(docker_zfs_agent_mounts) \
    -v "${SCRIPT_DIR}/lib:/app/lib" \
    -v "${SCRIPT_DIR}/config:/app/config" \
    -v "${SCRIPT_DIR}/priv:/app/priv" \
    -v "${SCRIPT_DIR}/assets:/app/assets" \
    ${HOMELAB_APPDATA_BIND:+-v "${HOMELAB_APPDATA_BIND}:/host/homelab/appdata:ro"} \
    -e HOMELAB_ADOPTION_SOURCE_ROOT="${HOMELAB_ADOPTION_SOURCE_ROOT:-/host/homelab/appdata}" \
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
