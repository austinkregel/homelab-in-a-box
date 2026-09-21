# Homelab-in-a-Box

One container that stands up the rest of your homelab.

Give it the Docker socket and a domain. It provisions its own Postgres, brings up Traefik with a wildcard certificate, and hands you a web UI for deploying apps, routing hostnames at them, backing them up, and watching everything else already running on the host.

Elixir, Phoenix LiveView, and the Docker Engine API. No agent to install, no compose files to hand-write, no YAML to keep in sync.

---

## Contents

- [Before you start](#before-you-start)
- [Install](#install)
- [Getting in](#getting-in)
- [Ingress: how apps become reachable](#ingress-how-apps-become-reachable)
- [Using it](#using-it)
- [Settings](#settings)
- [Environment variables](#environment-variables)
- [Keeping it running](#keeping-it-running)
- [Running from source](#running-from-source)

---

## Before you start

| What | Why |
|---|---|
| **A Docker host** | Linux, with a `/var/run/docker.sock` you can mount. The app runs as root and manages the daemon — the socket mount *is* the security boundary, same as Portainer. Docker Engine is the default orchestrator; Swarm works if the daemon is a manager. |
| **A domain you control** | The box answers at a hostname you pick, and deployed apps get names beneath it. |
| **A Cloudflare API token** | Certificates are issued by Let's Encrypt over the **DNS-01 challenge, Cloudflare only** — a token with `Zone:Read` and `Zone:DNS:Edit`. Without one the app will not provision Traefik at all, and nothing, including the UI, becomes reachable by name. You can supply it during install or later in the UI. |
| **An OIDC provider** | Authentik, Keycloak, Pocket ID, Zitadel — anything with `.well-known` discovery. There is no local password login. |
| **Ports 80 and 443 free** | Traefik binds them on the host. |

Optional: a Sentry DSN for crash reports, and somewhere off-box for backups to land.

> **Chicken and egg:** if the OIDC provider you want to use is itself going to run on this box, install anyway and use [break-glass](#locked-out) to get in the first time. Adopting or deploying the provider is a normal first task.

---

## Install

The app provisions everything underneath it, so the compose file runs only the app itself.

### 1. Configure

```bash
git clone https://github.com/austinkregel/homelab-in-a-box
cd homelab-in-a-box
cp .env.example .env
```

Fill in `.env`:

```bash
# Who you are
HOMELAB_INSTANCE_NAME=Homelab
HOMELAB_BASE_DOMAIN=homelab.example.com
PHX_HOST=homelab.example.com

# How you log in
HOMELAB_OIDC_ISSUER=https://id.example.com
HOMELAB_OIDC_CLIENT_ID=...
HOMELAB_OIDC_CLIENT_SECRET=...

# How TLS gets issued. Cloudflare token with Zone:Read + Zone:DNS:Edit.
# Optional here — you can instead paste it into Settings -> DNS & Domains
# after first boot. Set one way or the other, or nothing is reachable by name.
TRAEFIK_DNS_API_TOKEN=...
```

Register `https://<PHX_HOST>/auth/oidc/callback` as the redirect URI with your identity provider.

### 2. Start it

```bash
docker volume create homelab-iab-secrets
docker compose -f docker-compose.prod.yml up -d
docker logs -f homelab
```

The secrets volume is declared `external` on purpose, so `docker compose down -v` cannot remove it. It holds `secret_key_base`, which is also the key encrypting every credential in the database. Lose it and the stored OIDC secret, registry tokens, and generated database passwords become permanently unreadable ciphertext — while the data they unlock survives.

### 3. What first boot does

Before the app starts, it uses the socket to build its own foundation:

| Resource | Name |
|---|---|
| App database | `homelab-iab-postgres` — TimescaleDB (PG17), for time-series metrics |
| Job database | `homelab-iab-oban-postgres` — stock PG17, isolated so job churn stays off the app DB |
| Data volumes | `homelab-iab-postgres-data`, `homelab-iab-oban-postgres-data` |
| Secrets volume | `homelab-iab-secrets` |
| Network | `homelab-iab-internal` |

Everything is namespaced `homelab-iab-*` so it never collides with a `homelab-postgres` your existing stack may already own. Migrations run automatically on boot. Traefik comes up right after, unconditionally — not lazily on your first deploy.

Give it a minute or two. The container's healthcheck allows a 90-second start period for exactly this.

### 4. Finish setup

With `HOMELAB_SEED_SETUP=true` (set in the compose file), the values above are written straight into settings and setup is marked complete — *provided an OIDC issuer and client ID are both present*. If either is missing, the app deliberately leaves setup unfinished rather than switching on authentication with nowhere to send you, and the five-step wizard runs at `/setup` instead:

1. **Instance** — display name and base domain
2. **Authentication** — OIDC issuer, discovery, and a live connection test
3. **Infrastructure** — verifies the Docker socket, picks orchestrator (Engine or Swarm) and gateway
4. **First space** — name it
5. **Done**

> While setup is incomplete, authentication deliberately fails open. Finish it.

---

## Getting in

Sign-in is OIDC only. Who is allowed through is a separate question from who your provider will authenticate, because most issuers are not an access boundary — a public Google or GitHub app will mint a token for anyone alive.

**The first person to sign in becomes `admin`.** After that, an unknown user is provisioned only if:

- their email matches `oidc_allowed_emails` (Settings → Authentication; comma- or newline-separated, either a full address or a domain written `@example.com`), or
- `oidc_auto_provision` is on — the right choice when your issuer is a private IdP that only holds accounts it should.

Otherwise they are refused and the attempt is logged.

### Roles

| Role | Can |
|---|---|
| `member` | Read. Dashboard, catalog, deployments, domains, backups, activity, telemetry. |
| `admin` | Everything, including settings, deploying, storage, and the full container list. |
| `service` | Machine access via `client_credentials` tokens. |

Roles are read-versus-write, **not isolation between spaces**. A member sees every space's state.

### Locked out

If your identity provider is hosted on this box and it goes down, normal login is impossible — and the UI that would fix it is behind that login. Break-glass is the way back in, and it is single-use by design.

Arm it:

```bash
docker exec homelab bin/homelab rpc 'IO.puts(Homelab.Auth.BreakGlass.arm!())'
```

Copy the printed token and sign in at `/auth/break-glass`. A **successful** login deletes the token file, so the same token can never be used twice; a failed attempt does not consume it, so a typo can't lock you out. With no token file, the route 404s — the feature does not exist until you arm it.

Compose binds `127.0.0.1:4000` for precisely this: when Traefik or certificate issuance is what's broken, SSH-tunnel to that port to reach the break-glass page.

Every use, success or failure, lands in the activity log.

---

## Ingress: how apps become reachable

The app provisions its own Traefik and registers its own route — there is no static proxy config to maintain. Traefik takes 80 and 443, requests a certificate covering `<base_domain>` and `*.<base_domain>`, and routes by hostname.

This runs entirely on **DNS-01 against Cloudflare**; there is no HTTP-01 fallback. The credential is taken from the first of these that holds one:

1. `TRAEFIK_DNS_API_TOKEN` in the environment — still wins, so an instance feeding it from a Docker or Swarm secret is unaffected by the rest
2. **ACME DNS API token** in Settings → DNS & Domains
3. The **Cloudflare API token** already on that page for registrar sync and DNS records

(3) means that configuring Cloudflare in the UI is enough — it is the same credential Let's Encrypt needs. Traefik re-checks every five minutes and recreates itself on config drift, so a token pasted into Settings brings ingress up within that window with no restart. Certificates survive the recreate; `/letsencrypt` is a named volume.

Set a dedicated token under (2) only when the Cloudflare token you already store *cannot* edit DNS records — a registrar-only token is often read-only, and Let's Encrypt will reject it.

With no token anywhere, the app logs that it cannot provision Traefik and carries on without ingress. That is a supported configuration for a LAN-only install, not a failure. The DNS & Domains page names which source is in effect.

Point a wildcard `A` record at the host:

```
*.homelab.example.com.  A  <host public IP>
homelab.example.com.    A  <host public IP>
```

### Before the certificate exists

A domain bought this morning can be most of a day from resolving, and the box has to be usable in the meantime. So HTTPS is not forced until there is something to force it *to*:

| State | What the proxy does |
|---|---|
| Base domain does not resolve yet | Traefik runs with **no ACME resolver** and **no redirect**. The UI answers on plain HTTP. |
| Domain resolves, certificate not issued yet | ACME starts. Still no redirect — HTTP keeps working, HTTPS starts working the moment the certificate lands. |
| A real certificate is confirmed | The HTTP→HTTPS redirect switches on, permanently. |

The gate on the first row is about **Let's Encrypt's rate limits**, which is the part that actually costs you a day. LE caps *failed* validations at 5 per hour per hostname. A box left overnight against a domain that isn't delegated yet burns that budget on attempts that could never have worked, and is then still locked out for hours after DNS is finally ready. Holding ACME back until the name resolves is what makes it converge promptly instead.

The check is "does this name resolve at all", not "does it resolve to this host" — behind NAT the public record points at your router's WAN address while the container holds an RFC1918 one, and the stricter test would never pass. It also fails open: a resolver timeout or a SERVFAIL is treated as ready, because a false negative here costs you TLS permanently to avoid a transient rate-limit.

The flip to enforced HTTPS is decided by an actual TLS handshake against your domain, not by the proxy's own opinion — Traefik reports a route as healthy while serving its built-in self-signed cert, which is exactly the state this is trying to distinguish.

**It only ever moves one way.** A certificate that later expires or fails to renew raises alarms; it never silently drops the control plane back to plain HTTP. If you genuinely need to undo it, Settings → Danger Zone → *Stop enforcing HTTPS*.

One consequence worth knowing: during the plain-HTTP window, **OIDC login still won't complete**. The callback URL is built from `PHX_SCHEME`, so your IdP sends the browser back to `https://…` regardless. Use [break-glass](#locked-out) to get in and finish setup; normal login works once the certificate is issued.

### Hold pages

A deployment's route lives on its own container, so the moment the container isn't there, the hostname has nothing to answer it. Instead of a bare 404 or a proxy error, visitors get a branded interstitial that polls and reloads itself the second the app is back.

It names nothing about what is behind it — not the app, image, ports, space, or error — because on a stopped `sso_protected` app the guarding middleware is gone with the container's labels, and anyone who can resolve the name can reach that page. Eight states are chosen from the deployment itself (`setting_up`, `updating`, `starting`, `offline`, `unavailable`, `retired`, `unknown`, `control_plane`), and eleven more are named by status code at `/_hiab/hold/<code>` on any host the box routes. Only 502 and 504 land there by default; substituting your page for an app's own 401 or 500 hides a real answer, so the rest are opt-in.

---

## Using it

### Spaces

A space groups deployments with their own networking and volumes. You made one during setup; make more from **Spaces**. Suspended and archived spaces are listed there too — the sidebar shows only active ones.

(The schema still calls them tenants. Renaming the columns would mean a migration and orphaning every running container over a label.)

### Deploying an app

**Deploy → New deployment** walks five steps: *type → app → network → config → review*.

Pick an app from the catalog, or name any image. The catalog is assembled from sources you enable in Settings → Catalog:

| Source | What it is |
|---|---|
| Curated | Hand-maintained templates with env schemas |
| awesome-selfhosted | The community list |
| LinuxServer.io | The `lscr.io` images |
| hotio | The hotio images |
| OS bases | Plain base images |

You can also search Docker Hub, GHCR, and ECR Public directly, or paste a compose file and let the wizard parse it into services.

The wizard detects when an app wants a database and offers to add a companion with credentials wired in and generated — those are stored encrypted, and the databases the app declares are created on every release, not just the first (image entrypoints only initialize an empty data directory, which is where deployments otherwise stall).

Advanced settings are available *before* the first deploy, not only after: memory, CPU shares, routed port, sticky sessions, backend scheme, GPU, devices, capabilities, sysctls, restart policy, and replicas under Swarm.

### How a deploy actually runs

Every deploy is a **release**: an ordered, typed, compensatable plan you can watch step by step on the deployment's **Releases** tab. Stages run `prepare → dependencies → workload → namespace → naming → reachability → verification`, and each step records what it created so a failure can walk backwards and undo it.

The last step is the one that matters to you: `verify_public_url` asserts that `https://<domain>/` actually answers and that your app is what answered. Traefik still has to rebuild its router, ACME still has to issue, DNS still has to propagate — all three windows used to sit *after* a release had already reported success. This step fails loudly rather than rolling back, because everything it waits on is outside the deploy.

### Access modes

One choice per deployment, editable on its **Settings** tab:

| Mode | Reached how |
|---|---|
| **Reverse proxy** | Traefik at a domain, with auth: `public` (none), `sso_protected` (SSO), or `private` (IP allowlist) |
| **Host ports** | Container ports bound to the host. Never proxied. |
| **Host network** | Shares the host's namespace. Nothing to map, nothing to proxy — the daemon makes this exclusive. |
| **Internal only** | No external access. |

Exposure is a property of a *port*, not a container. A proxied deployment can still publish ports the proxy isn't carrying — a git server can answer HTTP on 3000 through Traefik while binding 22 on the host for `git push`. The one rule held is that on a **protected** deployment, the ports Traefik forwards to are never bound to the host: Traefik applies auth per router, so publishing a guarded backend port is no protection at all.

A deployment can also carry extra path routes (a second protocol on a second port) and extra host routes (a second hostname entirely — what Matrix needs for `.well-known` delegation).

### Domains & DNS

**Domains** has three tabs — zones, domains, and records.

Connect a registrar in Settings → DNS & Domains and your domain list syncs itself:

- **Registrars:** Cloudflare, Namecheap
- **Public DNS:** Cloudflare — A/CNAME records for public deployments
- **Internal DNS:** UniFi (legacy and new controller APIs), Pi-hole — split-horizon so LAN clients resolve to the LAN address

Records for a deployment are published automatically as part of its release, after the app is healthy — nothing advertises a name that isn't serving yet.

### Importing a stack you already run

**Settings → Import** takes over containers you started by hand, in place, without copying data.

A container is in scope when it has at least one bind mount under the **adoption root** (default `~/homelab`; set `HOMELAB_ADOPTION_ROOT` or change it in Settings → Infrastructure), isn't the app's own infrastructure, and isn't already managed.

Each mount is classified by tier, which decides how carefully it's handled:

| Tier | Meaning |
|---|---|
| `preserve` | Irreplaceable. A verified backup is a **mandatory** gate before cutover, and the reconciler will never reap it. This is the default for anything unclassified. |
| `rebuildable` | Repopulates itself — metric ingestion, model caches, search indexes. No backup gate. |
| `out_of_scope` | Not part of this homelab. Neither adopted, backed up, nor swept. |

You review the plan before anything runs. Then, per service: back up and verify, import existing credentials rather than generating new ones, stop the old container and disable its restart policy (so the daemon can't resurrect it into a double-writer), reattach a managed container to the *same* volumes, verify integrity, and only then remove the old one. One release per service, so a failure isolates. Re-running is idempotent.

For the saga to read those bytes, every path it touches must be mounted into the app container **at the same absolute path the daemon reports** — set `HOMELAB_ADOPTION_ROOT`, `HOMELAB_MANAGED_ROOT`, and `HOMELAB_BACKUP_ROOT`, and mount them. `HOMELAB_BACKUP_ROOT` especially: it defaults to the container's temp directory, so the one restorable copy standing between an adoption and your data would vanish with the container.

### Containers

**Containers** is the only page that shows *everything* on the daemon. Both orchestrator drivers list services filtered server-side by `homelab.managed=true`, so an unmanaged container isn't merely unlisted — the daemon never mentions it.

Three states, not two. The app's own containers carry no `managed` label (that label is an ownership claim the reconciler acts on; claiming them would sever the app's own routes and reap its database), so they report as system services rather than as strays. Out-of-scope containers are listed and labelled with the reason they were skipped, not filtered away.

### Storage

**Storage** joins physical disks, Docker's named volumes, and every host folder mounted into a deployment into one picture of where the bytes live and who put them there.

Volume sizes come from `GET /system/df`, which makes the daemon walk every volume and can take tens of seconds — the list renders immediately and sizes fill in. Deletion is guarded against the app's own records rather than Docker's `RefCount`, because `RefCount` only counts *running* containers, so a stopped app's data looks exactly like garbage.

Disks must be bind-mounted read-only to be charted; `df` inside a container only sees what it's given. `build_from_scratch.sh` takes `HOMELAB_DISKS="/mnt/tank:/mnt/tank /srv/backups:/mnt/backups"`; on compose, add the mounts yourself.

### Backups

Backups are Restic — encrypted, deduplicated, and able to target local disk, S3, SFTP, or anything else Restic speaks. Trigger one by hand, schedule it, or restore from the **Backups** page or a deployment's **Backups** tab. A scheduler dispatches due jobs in the background.

### Workbench

**Workbench** is for authoring an image rather than deploying one: write a Dockerfile, upload supporting files into a disk-backed workspace, build locally, and quick-run it with volumes, networks, and env wired for fast iteration.

Quick-run containers are labelled `homelab.workbench=true` and deliberately never `homelab.managed=true`, so the orphan sweep can't reap one out from under you mid-iteration. Promote a build to a real deployment from the Catalog page.

### Watching it

- **Dashboard** — host CPU, memory, disk, and current deployment state, live over PubSub
- **Telemetry** — CPU/memory/disk trends, Docker host state, and Traefik traffic against a selectable look-back window, backed by a TimescaleDB hypertable
- **Activity** — a persistent audit trail of every operation
- **Notifications** — deployment events, backup completions, containment actions

Container state comes from the Docker `/events` stream, so the UI moves the instant something starts, stops, or dies.

### Private registries

Settings → Registry provisions two system containers, both fronted by the existing Traefik and covered by the wildcard certificate:

- `homelab-registry` — authenticated push target at `registry.<base_domain>`, which Swarm nodes pull from
- `homelab-registry-proxy` — read-only pull-through cache of Docker Hub at `proxy-registry.<base_domain>`

They're separate containers because a registry in proxy mode cannot accept pushes. Nodes opt into the mirror with a one-time `daemon.json` entry.

Settings → Registries is a different thing: credentials for reading *external* registries (Docker Hub token for rate limits and private repos, a GitHub PAT for GHCR, AWS keys for ECR).

### The API

`/api/v1`, JSON, authenticated by your browser session or a `client_credentials` machine token carrying the scope set in `oidc_machine_scope` (default `homelab`).

| | |
|---|---|
| `GET /api/v1/health` | **Public.** Up/down per service plus the version — what the container healthcheck calls. |
| Reads | Any signed-in user or machine token: `/spaces`, `/spaces/:id/deployments`, `/spaces/:id/backups`, `/app-templates` |
| Writes | Admin only: creating, updating, and deleting spaces and deployments; creating and restoring backups |

Everything is scoped under its space. Writes are admin-gated because `POST /spaces/:id/deployments` accepts an image override — which is arbitrary-image execution on your Docker host — and restore overwrites live data. Refusals on the API come back as `403` JSON rather than a redirect, so a script can tell refused from succeeded.

---

## Settings

`/settings`, admin only, ten sections:

| Section | Holds |
|---|---|
| **General** | Instance name, base domain |
| **Authentication** | OIDC issuer, client ID and secret, auto-provisioning, allowed emails, machine scope |
| **Infrastructure** | Orchestrator, gateway, ACME email, adoption and managed roots, GPU and daemon facts |
| **DNS & Domains** | Registrar, public DNS provider, internal DNS provider, credentials, wildcard domains, and the DNS-01 credential in effect for TLS |
| **Registry** | The self-hosted registry and pull-through mirror |
| **Registries** | Docker Hub, GHCR, and ECR credentials |
| **Catalog** | Which catalog sources are enabled |
| **Import** | Adoption review and plan |
| **Users** | Roles |
| **Danger Zone** | Orphan sweep mode, recorded orphans, HTTPS enforcement, re-run setup |

Credentials are encrypted at rest with `secret_key_base`.

`/settings/export` dumps the instance's configuration as JSON.

---

## Environment variables

Set in `.env`; compose loads the whole file into the container.

### Required

| Variable | Notes |
|---|---|
| `PHX_HOST` | Public hostname. **The app refuses to boot in production without it** — this is what makes generated links and OIDC redirects correct instead of `localhost:4000`. |
| `HOMELAB_BASE_DOMAIN` | Base domain for deployment hostnames, registry hostnames, and the wildcard certificate. |
| `HOMELAB_OIDC_CLIENT_SECRET` | From your IdP. |

### TLS

| Variable | Notes |
|---|---|
| `TRAEFIK_DNS_API_TOKEN` | Cloudflare token for DNS-01. Takes precedence over both Settings sources. Not required here — see [Ingress](#ingress-how-apps-become-reachable) — but with no token in *any* source there is no Traefik and no ingress. |
| `TRAEFIK_DNS_RESOLVERS` | `1.1.1.1:53`. Point at the zone's authoritative nameservers if issuance stalls: DNSSEC-signed zones return a signed "no TXT" that validating resolvers cache far longer than lego's pre-check timeout. |
| `TRAEFIK_DNS_DISABLE_PROPAGATION_CHECK` | Skip lego's local propagation pre-check. Useful when a Pi-hole or `systemd-resolved` on the host serves it stale answers; the real validation is done by Let's Encrypt against the authoritative nameservers regardless. |
| `TRAEFIK_DNS_DELAY_BEFORE_CHECK` | Defaults to `30s` whenever the check above is disabled. |

### Seeding first boot

| Variable | Default |
|---|---|
| `HOMELAB_SEED_SETUP` | `true` in compose — writes the values below into settings and skips the wizard |
| `HOMELAB_INSTANCE_NAME` | `Homelab` |
| `HOMELAB_OIDC_ISSUER` | — |
| `HOMELAB_OIDC_CLIENT_ID` | — |
| `HOMELAB_ORCHESTRATOR` | `docker_engine` (or `docker_swarm`) |
| `HOMELAB_GATEWAY` | `traefik` |

### Runtime

| Variable | Default |
|---|---|
| `BOOTSTRAP` | `true` in the image — self-provision Postgres through the socket |
| `PHX_SERVER` | `true` in the image |
| `PHX_SCHEME` / `PHX_PORT` | `https` / `443` |
| `PORT` | `4000` |
| `DOCKER_SOCKET` | `/var/run/docker.sock` |
| `SECRET_KEY_BASE` | Generated once and persisted to the secrets volume. Set it explicitly only to manage it as a Docker/Swarm secret — **it must never change**, because it also encrypts every credential in the database. |
| `HOMELAB_SECRETS_DIR` | `/run/secrets` |
| `HOMELAB_IMAGE_TAG` | `latest`. Pin a release for reproducible deploys. |
| `HOMELAB_MEMORY_LIMIT` / `HOMELAB_CPU_LIMIT` | `1g` / `2` |
| `SENTRY_DSN` / `SENTRY_ENV` | Inert unless set |

### Adoption

| Variable | Default |
|---|---|
| `HOMELAB_ADOPTION_ROOT` | `~/homelab` — which binds are in scope |
| `HOMELAB_MANAGED_ROOT` | Where migrated data lands; must exist on host and container at the same path |
| `HOMELAB_BACKUP_ROOT` | The container's temp dir. **Point it somewhere that outlives the container.** |

### Break-glass

| Variable | Default |
|---|---|
| `HOMELAB_BREAKGLASS_TOKEN_FILE` | `<secrets dir>/breakglass_token` |
| `HOMELAB_BREAKGLASS_USER` | `breakglass` |

The token itself is never an environment variable.

### Without bootstrap

Running against databases you manage (`BOOTSTRAP=false`) requires both `DATABASE_URL` and `OBAN_DATABASE_URL`; the app raises on either being missing. Optional: `POOL_SIZE`, `OBAN_POOL_SIZE`, `ECTO_IPV6`.

---

## Keeping it running

### Health

```bash
curl -s https://homelab.example.com/api/v1/health | jq
```

Reports per-service up/down for the database, Docker event listener, backup scheduler, and cert manager, plus the version. `503` when the database is unreachable.

### The reconciler

A control loop runs every 20 seconds, and again on every reconnect of the Docker event stream. It converges each deployment's status to what the container is actually doing, times out deploys stuck in `deploying`, enforces the rule that a deployment holds a public route *if and only if* it is running, and flags deployments reachable by host port instead of through Traefik. Every containment action writes to the activity log and notifies admins.

It also sweeps **orphans** — a managed container with no deployment record. What happens then is yours to choose in Settings → Danger Zone:

| Mode | Behaviour |
|---|---|
| `sever_only` | **Default.** Cut the public route, notify, record the orphan — never delete. You remove them by hand. |
| `armed` | Sever, then delete after a grace period. Arming resets every grace clock, so nothing dies on the next tick. |
| `paused` | No orphan handling at all. Severed routes are not enforced. |

The orphan registry lives in memory. After a restart the next pass re-discovers and re-severs within one interval, and in `armed` mode the grace clock restarts — later is strictly safer than sooner.

### Upgrades

```bash
docker compose -f docker-compose.prod.yml pull
docker compose -f docker-compose.prod.yml up -d
```

Migrations run on boot. Pin `HOMELAB_IMAGE_TAG` to a release tag if you'd rather choose when that happens. Images are published to `ghcr.io/austinkregel/homelab-in-a-box` on each GitHub release.

### Starting over

```bash
./build_from_scratch.sh prod
```

This tears down the app's containers, volumes, and network — **including the secrets volume** — rebuilds the image, and starts fresh. That pairing is deliberate: removing the encryption key while keeping the database would leave every encrypted row as undecryptable ciphertext.

Note that the script runs `docker run` with an explicit env list and does **not** pass `TRAEFIK_DNS_API_TOKEN`. Since it also wipes the database, the Settings fallback is gone with it, so an instance started this way comes up without ingress and is reached at `127.0.0.1:4000` until you add a token in the UI. Use it for a reset or a dev loop; use compose for anything you intend to keep.

See [PRODUCTION.md](PRODUCTION.md) for Swarm, observability wiring, and recovery from known damage in earlier versions.

---

## Running from source

Elixir 1.19.5 and Erlang/OTP 28.3.3 (see [.tool-versions](.tool-versions)).

```bash
# Both databases — the app will not start without the Oban one
docker compose up -d postgres oban-postgres

mix setup
mix phx.server
```

`http://localhost:4000`. The Docker socket is used directly from the host in dev.

```bash
mix test              # or: mix test --failed
mix precommit         # warnings-as-errors, unused deps, format, tests
```

Agent and contributor playbooks live in [docs/agent/](docs/agent/) and [AGENTS.md](AGENTS.md).

---

## Built with

Elixir · Phoenix 1.8 · LiveView · Ecto · Oban · TimescaleDB · Bandit · Tailwind CSS v4 · Req · Traefik · Restic · the Docker Engine API

## License

MIT
