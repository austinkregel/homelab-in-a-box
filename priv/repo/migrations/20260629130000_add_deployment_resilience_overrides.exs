defmodule Homelab.Repo.Migrations.AddDeploymentResilienceOverrides do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      # Per-deployment overrides of the (shared) app_template resilience config.
      # NULL = inherit the template default.
      add :resource_limits_override, :map
      add :health_check_override, :map
    end
  end
end
