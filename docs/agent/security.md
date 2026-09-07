# Security playbook

## Known gaps (do not worsen without explicit intent)

| Issue | Location | Guidance |
|-------|----------|----------|
| Unauthenticated REST API | `/api/v1/*` | Add auth plug before exposing publicly |
| Vault stub | `Homelab.Storage.Secrets` | Falls back to Settings; `:vault_unavailable` until wired |
| Docker socket | Container mount | High privilege; consider socket-proxy pattern from homelab repo |
| Encryption at rest | `Homelab.Settings` | Derived from `SECRET_KEY_BASE` — protect in prod |

## Secrets handling

- Never commit `.env`, tokens, or OIDC client secrets
- Use `.env.example` as the only template in git
- `build_from_scratch.sh` loads `.env` — do not hardcode credentials in scripts
- Gitleaks runs via pre-commit (see `.pre-commit-config.yaml`)

## Elixir security scanning

```bash
mix sobelow --config        # Phoenix SAST (see .sobelow-conf; HTTPS/CSP at reverse proxy)
mix deps.audit              # Known CVEs in deps
mix hex.audit               # Retired Hex packages
```

Included in `mix precommit.ci`.

## Container / image scanning (CLI, agent-agnostic)

```bash
# Before deploying a catalog image
trivy image --severity HIGH,CRITICAL --format table <image:tag>

# Dockerfile in catalog / workbench
hadolint Dockerfile

# Repo secrets
gitleaks detect --source . --verbose
```

Optional MCP: [Trivy MCP](https://github.com/aquasecurity/trivy-mcp) (`trivy mcp`).

## Docker socket proxy pattern (homelab repo)

The operator homelab uses `tecnativa/docker-socket-proxy` with restricted flags (`EXEC=0`, `BUILD=0`, etc.). When suggesting homelab-in-a-box deployment hardening, reference that pattern rather than widening socket permissions.

## Auth boundaries

- LiveView: `RequireAuth` + `:require_auth` on_mount hook
- Setup wizard bypass until `Settings.setup_completed?/0`
- API: no plug today — flag any new routes that skip auth

## MCP config hygiene

- Store tokens in environment variables, not committed JSON
- Audit MCP configs periodically: `uvx snyk-agent-scan@latest` (optional)

## Policy-as-code (optional)

- **Conftest** / **OPA** for compose manifests in adoption/workbench flows
- **Checkov** for IaC if Terraform/Ansible is added later
