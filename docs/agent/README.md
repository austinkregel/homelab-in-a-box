# Agent playbooks

Portable workflows for any coding agent (Cursor, Claude Code, Copilot, Windsurf, etc.). Referenced from [`AGENTS.md`](../../AGENTS.md).

| Playbook | Use when |
|----------|----------|
| [domain.md](domain.md) | Bootstrap, behaviours, deployments, DNS, catalog |
| [security.md](security.md) | Secrets, API auth, Docker socket, scanning |
| [precommit.md](precommit.md) | Quality gates before commit or PR |
| [liveview-review.md](liveview-review.md) | LiveView / HEEx changes |
| [homelab-stack.md](homelab-stack.md) | Operator homelab Compose repo |
| [incident-triage.md](incident-triage.md) | Debugging outages with observability MCP |
| [mcp.json.example](mcp.json.example) | MCP server config template |

Install git hooks (optional): `pre-commit install` using [`.pre-commit-config.yaml`](../../.pre-commit-config.yaml).
