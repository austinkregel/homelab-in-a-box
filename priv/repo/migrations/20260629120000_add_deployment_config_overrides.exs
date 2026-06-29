defmodule Homelab.Repo.Migrations.AddDeploymentConfigOverrides do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      # Per-deployment overrides of the (shared) app_template config.
      # NULL = inherit the template default.
      add :ports_override, {:array, :map}
      add :exposure_mode_override, :string
    end
  end
end
