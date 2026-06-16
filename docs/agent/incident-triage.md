# Incident triage playbook

Agent-agnostic workflow using MCP (optional) or CLI. Assumes the operator homelab stack from [homelab-stack.md](homelab-stack.md).

## 1. Availability — Healthchecks

**Service**: LinuxServer Healthchecks container (`apps/healthchecks.yaml`).

- UI: hostname configured in Nginx Proxy Manager
- API: Healthchecks REST API (no official MCP — use `curl` or a thin custom MCP)

```bash
# Example: list checks (adjust URL and API key)
curl -s -u "api-key:KEY" "https://healthchecks.example/api/v1/checks/" | jq .
```

Determine which check failed and when the last ping was received.

## 2. Metrics — Prometheus

**Service**: `prometheus:9090` on internal Docker network.

Expose via NPM port-forward or temporary publish, then:

```bash
curl -s 'http://localhost:9090/api/v1/query?query=up' | jq .
```

**MCP** (copy from [mcp.json.example](mcp.json.example)):

- [prometheus-mcp-server](https://github.com/pab1it0/prometheus-mcp-server)
- Env: `PROMETHEUS_URL=http://localhost:9090` (or your NPM URL)

Useful queries: `up`, `rate(http_requests_total[5m])`, container memory from node-exporter.

## 3. Dashboards and logs — Grafana

**Service**: `grafana` container, data in `appdata/grafana`.

**MCP**: [grafana/mcp-grafana](https://github.com/grafana/mcp-grafana)

```bash
# Example install
uvx mcp-grafana
# Env: GRAFANA_URL, GRAFANA_SERVICE_ACCOUNT_TOKEN
```

Correlate Healthchecks failure time with Grafana dashboards and Loki logs (if configured).

## 4. Alerts — Alertmanager

**Service**: `alert-manager` in `apps/prometheus.yaml`.

**MCP**: [alertmanager-mcp-server](https://github.com/ntk148v/alertmanager-mcp-server)

- List firing alerts
- Create silences during remediation (with user approval)

## 5. Application layer — homelab-in-a-box

If the control plane manages the failing deployment:

- Check deployment health in LiveView dashboard
- Logs: application logs / `Homelab.Services` activity log
- Do not restart production containers via agent without explicit user request

## 6. Control plane issues

If homelab-in-a-box itself is down:

```bash
docker logs homelab --tail 200
curl -s http://localhost:4000/api/v1/health
```

## MCP enablement checklist

1. Copy [mcp.json.example](mcp.json.example) to your agent config path (see README table)
2. Set env vars for Grafana/Prometheus tokens
3. Port-forward or NPM proxy internal services to localhost
4. Enable only ops MCP servers during incidents (reduces tool noise)

## Escalation

- Media stack: verify gluetun VPN container is healthy first
- Matrix: known first-boot failures per homelab README
- Database: check `homelab-postgres` / MariaDB healthchecks before app logs
