# Domain playbook — homelab-in-a-box

## Architecture

- **Runtime**: Elixir/OTP supervisors, GenServers, Phoenix PubSub
- **Web**: Phoenix LiveView (`HomelabWeb.*`), Bandit
- **Data**: PostgreSQL + Ecto (auto-migrate on boot in container)
- **Orchestration**: Docker Engine (primary); Docker Swarm behaviour exists
- **Gateway**: Traefik (not Nginx Proxy Manager — that is the separate homelab repo)
- **HTTP client**: Req only — never HTTPoison/Tesla/httpc

## Key modules

| Area | Path |
|------|------|
| Bootstrap / self-provision | `lib/homelab/bootstrap.ex` |
| Docker client | `lib/homelab/docker/` |
| Deployments | `lib/homelab/deployments/` |
| Catalog enrichers | `lib/homelab/catalog/enrichers/` |
| Orchestrators | `lib/homelab/orchestrators/` |
| DNS / registrars | `lib/homelab/dns/`, `lib/homelab/registrars/` |
| Backups | `lib/homelab/backups/`, `lib/homelab/backup_providers/` |
| Storage (ZFS) | `lib/homelab/storage/` |
| Settings / encryption | `lib/homelab/settings.ex` |
| Secrets facade | `lib/homelab/storage/secrets.ex` |

## Behaviour injection

Production uses real implementations; tests swap via `config/test.exs` and Mox (`test/support/mocks.ex`). When adding integrations, define a behaviour and fake driver first.

## Docker events

Prefer PubSub / event listeners over polling Docker state in loops.

## Tenants and deployments

- Multi-tenant **spaces** with isolated deployments
- Deploy wizard: `HomelabWeb.DeployWizardLive`
- Spec building: `Homelab.Deployments.SpecBuilder`

## ZFS host agent

The BEAM container talks to ZFS only via `HOMELAB_ZFS_AGENT_SOCKET` on the host — never bundle zfsutils in the image. See `build_from_scratch.sh` for mount wiring.

## Local dev

```bash
docker compose up -d    # Postgres on 5433
mix setup && mix phx.server
```

Full stack rebuild: `./build_from_scratch.sh` (requires `.env` from `.env.example`).
