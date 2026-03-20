# Homelab-in-a-Box

A self-bootstrapping, Docker-native homelab management platform built with Elixir and Phoenix LiveView. Deploy it with a single command and manage your entire self-hosted infrastructure through a real-time web interface.

## Quick Start

```bash
docker run -it --rm \
  --name homelab \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -p 4000:4000 \
  homelab-in-a-box:latest
```

That's it. Open `http://localhost:4000` and the setup wizard will guide you through initial configuration.

## What It Does

Homelab-in-a-Box is a control plane for your self-hosted infrastructure. It provisions its own database, manages containers through the Docker API, and gives you a polished UI to deploy and monitor applications -- all from a single container.

### Architecture

```
┌───────────────────────────────────┐
│        Homelab-in-a-Box           │
│     (Elixir/Phoenix LiveView)     │
│                                   │
│  ┌─────────┐  ┌────────────────┐  │
│  │ Bootstrap│  │  OTP Services  │  │
│  │ Module   │  │  (DockerEvent  │  │
│  │          │  │   Listener,    │  │
│  │          │  │   CatalogSync) │  │
│  └────┬─────┘  └───────┬────────┘  │
│       │                │           │
│       └──── Docker Socket ─────────┤
│            /var/run/docker.sock    │
└───────────────┬───────────────────┘
                │
    ┌───────────┼───────────────┐
    │           │               │
┌───▼──┐  ┌────▼────┐  ┌───────▼──────┐
│Postgres│ │ Traefik │  │ Your Apps    │
│  (auto │ │ (reverse│  │ (Nextcloud,  │
│  prov.)│ │  proxy) │  │  Gitea, etc) │
└────────┘ └─────────┘  └──────────────┘
```

### Features

- **Self-Bootstrapping**: Automatically provisions its own Postgres database and networking on first run
- **Setup Wizard**: Guided first-run configuration for OIDC authentication, Docker connectivity, and initial workspace setup
- **OIDC Authentication**: Integrates with external identity providers (Authentik, Keycloak, etc.) via `.well-known` discovery
- **Curated App Catalog**: 140+ hand-picked, server-side Docker applications with accurate image refs, ports, volumes, and env vars -- covering media, databases, monitoring, VPN, wikis, chat, CI/CD, and more. Catalog is stored as a JSON file (`priv/catalog/curated.json`) and can be extended by editing it directly
- **Multi-Registry Search**: Discover additional container images on demand from:
  - Docker Hub (search any public image)
  - GitHub Container Registry (GHCR)
  - AWS Elastic Container Registry (ECR Public)
- **Event-Driven Docker Engine**: Real-time container status via the Docker `/events` stream -- no polling or reconciliation cycles. Deployments update instantly in the UI as containers start, stop, or fail
- **Container Lifecycle Management**: Deploy, stop, start, restart, and destroy containers with real-time status updates
- **Deployment Details**: Per-container log viewer with live follow, error banners for failed deployments, environment editor, volume management, and backup controls
- **Host Monitoring**: CPU, memory, and disk usage gauges with live updates via PubSub
- **Domain Management**: Registrar syncing (Cloudflare, Namecheap), DNS zones, and automatic DNS record creation for deployments across public (Cloudflare) and internal (UniFi, Pi-hole) DNS providers
- **Backup Management**: Trigger, schedule, and restore backups across deployments
- **Activity Logging**: Persistent audit trail of all system operations with database-backed storage
- **Notifications**: Real-time notification system for deployment events, backup completions, and system alerts
- **Infrastructure Services**: Auto-provision reverse proxies (Traefik), DNS (Pi-hole), and other system-level services
- **Multi-Tenant Spaces**: Isolate deployments into separate workspaces with scoped networking and volumes
- **Docker Volume Strategy**: Named volumes for all persistent data (no bind-mount sprawl)

## Development Setup

### Prerequisites

- Elixir 1.15+
- PostgreSQL (via Docker Compose or local install)
- Docker (for container management features)

### Getting Started

```bash
# Start the dev database
docker compose up -d postgres

# Install dependencies and set up the database
mix setup

# Start the dev server
mix phx.server
```

Visit `http://localhost:4000`.

### Fresh Start Testing

To test the full bootstrap flow from scratch:

```bash
./build_from_scratch.sh
```

This tears down all homelab containers, volumes, and networks, rebuilds the Docker image, and starts fresh.

### Running Tests

```bash
mix test
```

### Code Quality

```bash
mix precommit
```

This runs compilation with warnings-as-errors, dependency cleanup, formatting, and tests.

## Configuration

### Environment Variables

| Variable | Description | Default |
|---|---|---|
| `BOOTSTRAP` | Enable self-provisioning mode | `false` |
| `DATABASE_URL` | Postgres connection string (non-bootstrap mode) | — |
| `SECRET_KEY_BASE` | Phoenix secret key | Auto-generated |
| `PHX_HOST` | Hostname for the app | `localhost` |
| `PHX_SERVER` | Enable the web server | `true` |
| `PORT` | HTTP port | `4000` |
| `DOCKER_SOCKET` | Path to Docker socket | `/var/run/docker.sock` |

### Registrar & DNS Providers

Domain registrar and DNS provider integrations are configured through the Settings page:

- **Registrars** (sync your domain list automatically):
  - Cloudflare -- API token authentication
  - Namecheap -- API user/key authentication
- **Public DNS**:
  - Cloudflare -- manage A/CNAME records for public-facing deployments
- **Internal DNS** (split-horizon for LAN access):
  - UniFi Network -- legacy and new controller APIs
  - Pi-hole -- custom DNS records via API

### Registry Drivers

Registry credentials are configured through the Settings page after initial setup:

- **Docker Hub**: Optional token for rate limit increases and private repos
- **GHCR**: GitHub Personal Access Token for private packages
- **AWS ECR**: Access Key, Secret Key, and Region for private repositories

## Tech Stack

- **Elixir** + **Phoenix 1.8** + **Phoenix LiveView** -- real-time server-rendered UI
- **Ecto** -- database layer with auto-migrations on startup
- **OTP** -- supervision trees, GenServers, PubSub for event-driven services
- **Docker Engine API** -- container orchestration and event streaming via Unix socket
- **Tailwind CSS v4** -- utility-first styling
- **Req** -- HTTP client for Docker API, registrars, DNS providers, and external registries

## License

MIT
