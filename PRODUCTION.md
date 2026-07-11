# Production Deployment

This guide covers running homelab-in-a-box in production. It assumes a single
Docker host to start, with a path to Docker Swarm later.

## How it provisions itself

When `BOOTSTRAP=true` (the default in the release image), the app uses the
mounted Docker socket to create and manage its **own** Postgres:

| Resource        | Name                       | Notes                                        |
| --------------- | -------------------------- | -------------------------------------------- |
| DB container    | `homelab-iab-postgres`     | `postgres:17-alpine`, user `homelab`         |
| DB data volume  | `homelab-iab-postgres-data`| Survives restarts                            |
| Secrets volume  | `homelab-iab-secrets`      | Holds the pg password + `secret_key_base`    |
| Network         | `homelab-iab-internal`         | Shared with app containers it manages         |

These are namespaced `homelab-iab-*` specifically so they never collide with a
shared `homelab-postgres` that may already exist on the host (e.g. your main
compose stack's database). Migrations run automatically on boot.

## 1. Secrets and config

Copy the example file and fill it in (it is gitignored):

```bash
cp .env.example .env
```

Required:

- `HOMELAB_OIDC_CLIENT_SECRET` — **rotate this in your IdP.** The previous value
  was committed to git history and must be considered compromised.
- `HOMELAB_BASE_DOMAIN` / `PHX_HOST` — the public hostname (e.g.
  `homelab.example.com`). This is what fixes generated URLs/redirects;
  without it the app refuses to boot in prod (no more silent `localhost:4000`).

Optional but recommended:

- `SECRET_KEY_BASE` — if unset, a stable value is generated once and persisted
  to the `homelab-iab-secrets` volume. **Do not let it change**: it also
  encrypts every credential stored in the database, so rotating it makes
  existing encrypted settings unreadable. Set it explicitly only if you intend
  to manage it as a Docker/Swarm secret.
- `SENTRY_DSN` — point at your stack's Sentry to receive crash reports.

## 2. Deploy (single node)

Either path builds `homelab-in-a-box:latest` and runs it detached with a
restart policy, resource limits, healthcheck, and the durable secrets volume.

**Quick / from-scratch (rebuilds, wipes the iab volumes):**

```bash
./build_from_scratch.sh prod
docker logs -f homelab
```

**Compose (recommended for ongoing operation; preserves data across restarts):**

```bash
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml logs -f
```

> `build_from_scratch.sh` is destructive by design — it tears down and removes
> the `homelab-iab-*` containers/volumes each run. Use it for the initial build
> or a clean reset; use the compose file for restarts and upgrades.

## 3. Reverse proxy (nginx-proxy-manager)

The app listens on port 4000. In NPM add a Proxy Host:

- Domain: your `PHX_HOST`
- Scheme: `http`, Forward host/port: the app at `4000` (host IP if you publish
  the port, or the container name if NPM shares a network with it)
- Enable SSL (Let's Encrypt) and "Websockets Support" (required for LiveView)

TLS terminates at NPM; the app is told its public URL is `https://$PHX_HOST:443`
via `PHX_SCHEME`/`PHX_PORT`, so generated links and the OIDC redirect URI are
correct.

## 4. OIDC

After setting `PHX_HOST`, register this redirect URI in your identity provider:

```
https://<PHX_HOST>/auth/oidc/callback
```

(Previously it would have been `http://localhost:4000/auth/oidc/callback`.)
A mismatch here is the most common post-deploy login failure.

## 5. Observability

- **Health:** `GET /api/v1/health` returns 200 when the DB is reachable, 503
  otherwise. The container `HEALTHCHECK` uses it.
- **Metrics:** Prometheus format is exposed on port **9568** at `/metrics`
  (only started in prod). It is intentionally not published or proxied; let
  Prometheus reach it over a shared Docker network. Scrape config:

  ```yaml
  - job_name: homelab-in-a-box
    static_configs:
      - targets: ["homelab:9568"]
  ```

  For this to work, attach Prometheus and this app to a common network (see the
  commented "stack-internal" block in `docker-compose.prod.yml`).
- **Logs:** structured JSON in prod (`docker logs homelab`).
- **Errors:** set `SENTRY_DSN` to enable Sentry reporting.

## 6. Backups

The database lives in the `homelab-iab-postgres-data` volume. Back it up with a
logical dump:

```bash
docker exec homelab-iab-postgres pg_dump -U homelab homelab_prod | gzip > homelab-$(date +%F).sql.gz
```

Also preserve `homelab-iab-secrets` (or your explicit `SECRET_KEY_BASE`):
without the same `secret_key_base`, encrypted settings in a restored DB cannot
be decrypted.

## 7. Upgrades

```bash
# rebuild image, then:
docker compose -f docker-compose.prod.yml up -d
```

Migrations run automatically on boot. The data and secrets volumes persist.

## 8. Path to Swarm

When you convert the node to a manager and join others:

- Render the stack with env baked in, since `docker stack deploy` ignores
  `env_file:`:

  ```bash
  docker compose -f docker-compose.prod.yml config | docker stack deploy -c - homelab
  ```

  Or migrate secrets to `docker secret` and reference them.
- Caveats to plan for:
  - The `homelab-iab-*` volumes are **node-local**. Pin the app (and its
    self-provisioned Postgres) to one node, or move to networked storage.
  - Your existing `socket-proxy` is configured with `SWARM=0`; swarm-level
    management through it is blocked. The app's container provisioning uses the
    plain container API, which the proxy does allow.
  - Consider switching `HOMELAB_ORCHESTRATOR` to `docker_swarm` once running on
    a swarm.

## Verification checklist

- [ ] `.env` has a rotated `HOMELAB_OIDC_CLIENT_SECRET` and `PHX_HOST`
- [ ] `docker logs homelab` shows "Bootstrap: infrastructure ready" and the server booting
- [ ] `curl -fsS http://<host>:4000/api/v1/health` returns 200
- [ ] OIDC login round-trips (redirect URI registered)
- [ ] App URL has no `localhost:4000` anywhere
- [ ] Restarting the container keeps you logged in (stable `secret_key_base`)
- [ ] Prometheus is scraping `:9568/metrics` (if integrated)
