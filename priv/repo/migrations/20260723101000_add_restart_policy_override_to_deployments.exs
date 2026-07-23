defmodule Homelab.Repo.Migrations.AddRestartPolicyOverrideToDeployments do
  use Ecto.Migration

  # How a container behaves when it exits (NULL = the platform default, on-failure/3).
  #
  # This was not merely uneditable, it was unsettable: both drivers hardcoded
  # `on-failure` with three attempts and nothing anywhere could say otherwise. Fine
  # for a web app, wrong for two common cases -- a one-shot job that SHOULD stay
  # stopped after it succeeds, and a datastore an operator wants to come back up
  # unconditionally after a host reboot.
  #
  # Adoption made it worse: AdoptionDiscovery already reads the original container's
  # policy and then throws it away, so adopting an `always` container silently
  # downgraded it to on-failure/3.
  def change do
    alter table(:deployments) do
      add :restart_policy_override, :string
    end
  end
end
