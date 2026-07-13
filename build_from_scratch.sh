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

# Emergency, non-OIDC admin login. Since the OIDC provider is itself hosted here,
# break-glass is what lets you reach the UI (to adopt/repair that provider) when
# it's down. The token is NOT set here — it lives in a one-time file inside the
# homelab-iab-secrets volume and is deleted the moment it's used. Arm it AFTER
# startup, copy the printed token, and use it once (portable across dev/prod):
#   docker exec homelab sh -c 'od -An -N24 -tx1 /dev/urandom | tr -d " \n" \
#     | tee /run/secrets/breakglass_token; chmod 600 /run/secrets/breakglass_token'
# (prod release image also supports: bin/homelab rpc '...BreakGlass.arm!()')
HOMELAB_BREAKGLASS_USER="${HOMELAB_BREAKGLASS_USER:-breakglass}"

if [ -z "${HOMELAB_OIDC_CLIENT_SECRET}" ]; then
  echo "WARNING: HOMELAB_OIDC_CLIENT_SECRET is empty — OIDC login will fail." >&2
  echo "         Copy .env.example to .env and set it (and rotate the old secret)." >&2
fi

# --- Physical disks to expose for disk telemetry ---
# Bind-mount host disks (read-only) so they appear in the dashboard's Disk usage
# section. `df` inside the container can only see mounts it's given, so a disk
# must be passed in here to be charted.
#
# HOMELAB_DISKS is a space-separated list of `HOST_PATH:CONTAINER_PATH` pairs;
# each is mounted read-only. Mount a disk's host mountpoint (not the raw block
# device) and, by convention, expose it under /mnt so the label is obvious:
#   HOMELAB_DISKS="/mnt/tank:/mnt/tank /srv/backups:/mnt/backups"
DISK_MOUNT_ARGS=()
for pair in ${HOMELAB_DISKS:-}; do
  DISK_MOUNT_ARGS+=(-v "${pair}:ro")
  echo "==> Exposing disk: ${pair} (read-only)"
done

# --- Adoption / migration roots -------------------------------------------
#
# Adoption does real filesystem work from INSIDE this container: the backup gate
# File.cp_r's each preserve target, and a :migrate copies it into the managed root.
# Scope matching is a string compare against the daemon's bind sources, but reading
# the bytes is not — so every path the saga touches must be mounted here, at the
# SAME absolute path the daemon reports. Without that, discovery finds the stack and
# the backup gate then fails on every target.
#
#   HOMELAB_ADOPTION_ROOT — host dir delimiting which binds are in scope (read-only:
#                           we only ever READ the original data; the adopted container
#                           mounts it itself, via the daemon, not through us).
#   HOMELAB_MANAGED_ROOT  — where :migrate puts the copy. The daemon device-binds this
#                           path on the HOST, so it must exist on both sides at the
#                           same path or the volume mounts empty.
#   HOMELAB_BACKUP_ROOT   — where the backup gate writes. Defaults to the container's
#                           temp dir, which does not outlive the container.
ADOPTION_MOUNT_ARGS=()
ADOPTION_ENV_ARGS=()

if [ -n "${HOMELAB_ADOPTION_ROOT:-}" ]; then
  ADOPTION_MOUNT_ARGS+=(-v "${HOMELAB_ADOPTION_ROOT}:${HOMELAB_ADOPTION_ROOT}:ro")
  ADOPTION_ENV_ARGS+=(-e "HOMELAB_ADOPTION_ROOT=${HOMELAB_ADOPTION_ROOT}")
  echo "==> Adoption root: ${HOMELAB_ADOPTION_ROOT} (read-only)"

  # A named volume's data lives under the daemon's root, not on the host FS. To back
  # up (or migrate) a service whose data is a named volume — Laravel Sail's mysql, for
  # one — we must be able to read the volume's mountpoint.
  ADOPTION_MOUNT_ARGS+=(-v /var/lib/docker/volumes:/var/lib/docker/volumes:ro)
fi

if [ -n "${HOMELAB_MANAGED_ROOT:-}" ]; then
  mkdir -p "${HOMELAB_MANAGED_ROOT}"
  ADOPTION_MOUNT_ARGS+=(-v "${HOMELAB_MANAGED_ROOT}:${HOMELAB_MANAGED_ROOT}")
  ADOPTION_ENV_ARGS+=(-e "HOMELAB_MANAGED_ROOT=${HOMELAB_MANAGED_ROOT}")
  echo "==> Managed root: ${HOMELAB_MANAGED_ROOT}"
fi

if [ -n "${HOMELAB_BACKUP_ROOT:-}" ]; then
  mkdir -p "${HOMELAB_BACKUP_ROOT}"
  ADOPTION_MOUNT_ARGS+=(-v "${HOMELAB_BACKUP_ROOT}:${HOMELAB_BACKUP_ROOT}")
  ADOPTION_ENV_ARGS+=(-e "HOMELAB_BACKUP_ROOT=${HOMELAB_BACKUP_ROOT}")
  echo "==> Backup root: ${HOMELAB_BACKUP_ROOT}"
fi

NETWORK="homelab-iab-internal"

# Anything carrying `homelab.adopted=true` is an ADOPTED user service — e.g. a
# self-hosted OIDC server and its database — whose real data lives on this host.
# The plane took it over in place (see Homelab.Deployments.Adoption); a rebuild
# must NEVER destroy it. Docker's filter language can't express label negation,
# so we compute the set of protected ids up front and skip them by hand below.
ADOPTED_CTRS="$(docker ps -aq --filter 'label=homelab.adopted=true' 2>/dev/null || true)"
ADOPTED_VOLS="$(docker volume ls -q --filter 'label=homelab.adopted=true' 2>/dev/null || true)"

is_protected() { # id, protected-list
  [ -n "$1" ] && printf '%s\n' $2 | grep -qx -- "$1"
}

remove_unadopted_containers() { # label
  docker ps -aq --filter "label=$1" 2>/dev/null | while read -r id; do
    [ -z "$id" ] && continue
    if is_protected "$id" "$ADOPTED_CTRS"; then
      echo "==> Preserving adopted container ${id}"
    else
      docker rm -f "$id" >/dev/null 2>&1 || true
    fi
  done
}

echo "==> Tearing down existing homelab infrastructure..."
docker stop homelab homelab-iab-postgres homelab-iab-oban-postgres 2>/dev/null || true
docker rm homelab homelab-iab-postgres homelab-iab-oban-postgres 2>/dev/null || true

# Clean up managed and system containers before removing the network — but leave
# adopted services running.
remove_unadopted_containers "homelab.managed=true"
remove_unadopted_containers "homelab.system=true"

echo "==> Removing volumes (preserving adopted data)..."
docker volume rm homelab-iab-postgres-data homelab-iab-oban-postgres-data homelab-iab-secrets 2>/dev/null || true
# All plane-created volumes are prefixed `homelab-`. Purge them EXCEPT any labeled
# `homelab.adopted=true` (e.g. `homelab-managed-*`, which backs adopted DB data).
docker volume ls -q --filter "name=homelab-" 2>/dev/null | while read -r v; do
  [ -z "$v" ] && continue
  if is_protected "$v" "$ADOPTED_VOLS"; then
    echo "==> Preserving adopted volume ${v}"
  else
    docker volume rm "$v" >/dev/null 2>&1 || true
  fi
done

echo "==> Removing network..."
docker network rm "${NETWORK}" 2>/dev/null || true

# On a swarm-enabled daemon the backbone MUST be an overlay: Swarm refuses to
# attach a service to a node-local bridge ("cannot be used with services"), and
# routed deployments join this network so Traefik can reach them. `attachable` is
# what still lets plain containers — the app itself, Traefik, Postgres — join it.
echo "==> Creating shared network..."
if [ "$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = "active" ]; then
  docker network create --driver overlay --attachable "${NETWORK}" 2>/dev/null || true
else
  docker network create "${NETWORK}" 2>/dev/null || true
fi

if [ "$MODE" = "prod" ]; then
  echo "==> Building production image..."
  docker build -t homelab-in-a-box:latest . --pull --no-cache

  # No Traefik labels here on purpose: the app provisions Traefik AND registers its
  # own ingress route + wildcard cert at runtime (Homelab.Services.GatewayProvisioner
  # -> Homelab.Infrastructure.ensure_self_ingress/0). Keeping the launch minimal is
  # the whole point — management is automated away from static config.
  echo "==> Starting homelab-in-a-box (prod, detached)..."
  docker run -d \
    --name homelab \
    --restart unless-stopped \
    --memory "${HOMELAB_MEMORY_LIMIT:-1g}" \
    --cpus "${HOMELAB_CPU_LIMIT:-2}" \
    --network "${NETWORK}" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v homelab-iab-secrets:/run/secrets \
    ${DISK_MOUNT_ARGS[@]+"${DISK_MOUNT_ARGS[@]}"} \
    ${ADOPTION_MOUNT_ARGS[@]+"${ADOPTION_MOUNT_ARGS[@]}"} \
    ${ADOPTION_ENV_ARGS[@]+"${ADOPTION_ENV_ARGS[@]}"} \
    -e HOMELAB_SEED_SETUP=true \
    -e HOMELAB_INSTANCE_NAME="${HOMELAB_INSTANCE_NAME}" \
    -e HOMELAB_BASE_DOMAIN="${HOMELAB_BASE_DOMAIN}" \
    -e HOMELAB_OIDC_ISSUER="${HOMELAB_OIDC_ISSUER}" \
    -e HOMELAB_OIDC_CLIENT_ID="${HOMELAB_OIDC_CLIENT_ID}" \
    -e HOMELAB_OIDC_CLIENT_SECRET="${HOMELAB_OIDC_CLIENT_SECRET}" \
    -e HOMELAB_ORCHESTRATOR="${HOMELAB_ORCHESTRATOR}" \
    -e HOMELAB_GATEWAY="${HOMELAB_GATEWAY}" \
    -e HOMELAB_BREAKGLASS_USER="${HOMELAB_BREAKGLASS_USER}" \
    -e PHX_HOST="${HOMELAB_BASE_DOMAIN}" \
    -e PHX_SCHEME="https" \
    -e PHX_PORT="443" \
    -p 127.0.0.1:4000:4000 \
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
    ${DISK_MOUNT_ARGS[@]+"${DISK_MOUNT_ARGS[@]}"} \
    ${ADOPTION_MOUNT_ARGS[@]+"${ADOPTION_MOUNT_ARGS[@]}"} \
    ${ADOPTION_ENV_ARGS[@]+"${ADOPTION_ENV_ARGS[@]}"} \
    -e HOMELAB_SEED_SETUP=true \
    -e HOMELAB_INSTANCE_NAME="${HOMELAB_INSTANCE_NAME}" \
    -e HOMELAB_BASE_DOMAIN="${HOMELAB_BASE_DOMAIN}" \
    -e HOMELAB_OIDC_ISSUER="${HOMELAB_OIDC_ISSUER}" \
    -e HOMELAB_OIDC_CLIENT_ID="${HOMELAB_OIDC_CLIENT_ID}" \
    -e HOMELAB_OIDC_CLIENT_SECRET="${HOMELAB_OIDC_CLIENT_SECRET}" \
    -e HOMELAB_ORCHESTRATOR="${HOMELAB_ORCHESTRATOR}" \
    -e HOMELAB_BREAKGLASS_USER="${HOMELAB_BREAKGLASS_USER}" \
    -e PHX_HOST="${HOMELAB_BASE_DOMAIN}" \
    -e PHX_SCHEME="https" \
    -e PHX_PORT="443" \
    -e HOMELAB_GATEWAY="${HOMELAB_GATEWAY}" \
    -p 4000:4000 \
    homelab-in-a-box:dev
fi

