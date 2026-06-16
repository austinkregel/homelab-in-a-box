# Homelab stack playbook (operator repo)

The live Compose stack is maintained separately (e.g. `homelab` at `~/src/homelab`). homelab-in-a-box is the **control plane**; the homelab repo is what it often manages or coexists with.

## Quick commands

```bash
cd ~/src/homelab
make setup    # first-time appdata / prometheus config
make up       # docker compose --profile all
make help
```

Wrapper: `bin/homelab.sh` → `docker compose --project-directory "$ROOT_DIR" --profile all`.

## Core services (from docker-compose.yaml includes)

| Service | File | Notes |
|---------|------|-------|
| Postgres / MariaDB | `apps/postgres.yaml`, `apps/mariadb.yaml` | Shared DBs |
| Nginx Proxy Manager | `apps/nginx-reverse-proxy.yaml` | Ports 80/81/443 |
| Prometheus stack | `apps/prometheus.yaml` | Prometheus, Alertmanager, Grafana, InfluxDB, node-exporter |
| Healthchecks | `apps/healthchecks.yaml` | Status monitoring (not Uptime Kuma) |
| aut.hair | `apps/personal-apps.yaml` | OIDC provider for homelab-in-a-box |
| docker-socket-proxy | `apps/socket-proxy.yaml` | Restricted Docker API |
| Watchtower | `apps/watchtower.yaml` | Scheduled image updates |
| Media stack | `apps/media-stack.yaml`, `apps/plex.yaml` | VPN via gluetun |

## Compose profiles

- `all` — full stack via `make up`
- `personal`, `core`, `miscellaneous` — per-service profiles in individual yaml files

## Networks

- `docker`, `internal`, `public` bridges defined in root `docker-compose.yaml`

## Secrets pattern

- Root `.env` for PUID/PGID/TZ and DB passwords (gitignored)
- InfluxDB uses Docker secrets from `~/.env.influxdb2-*` files (see `apps/prometheus.yaml`)

## Relationship to homelab-in-a-box

| homelab repo | homelab-in-a-box |
|--------------|------------------|
| NPM reverse proxy | Traefik gateway |
| Prometheus/Grafana | Dashboard metrics from Docker/Traefik |
| aut.hair OIDC | `AuthController` + setup seed env vars |
| socket-proxy | Raw socket mount (hardening opportunity) |

When documenting URLs for MCP or debugging, use the hostnames configured in NPM for Grafana/Prometheus/Healthchecks.
