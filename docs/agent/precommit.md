# Precommit playbook

## Before finishing any change

```bash
mix precommit
```

Runs: `compile --warnings-as-errors` → `deps.unlock --unused` → `format` → `credo --min-priority high` (informational; legacy warnings) → `test`.

## Before opening a PR / CI parity

```bash
mix precommit.ci
```

Adds: `format --check-formatted`, `sobelow --config`, `deps.audit`, `hex.audit`.

## Targeted testing

```bash
mix test test/homelab_web/live/dashboard_live_test.exs
mix test test/homelab_web/live/dashboard_live_test.exs:28
mix test --failed
```

## Git hooks (all agents)

```bash
pip install pre-commit   # or brew install pre-commit
pre-commit install
```

Hooks: `mix precommit` on Elixir file changes + gitleaks on every commit.

## CI

GitHub Actions runs `mix precommit.ci` on push/PR — see `.github/workflows/ci.yml`.

## Coverage (optional)

```bash
mix coveralls.html
```

Threshold configured in `coveralls.json` (80% minimum).
