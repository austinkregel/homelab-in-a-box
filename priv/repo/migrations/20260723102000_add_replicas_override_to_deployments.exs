defmodule Homelab.Repo.Migrations.AddReplicasOverrideToDeployments do
  use Ecto.Migration

  # How many tasks a Swarm service runs (NULL = 1).
  #
  # `replicas` was declared in the service_spec type and then hardcoded to 1 at the
  # only place it was built, so the field looked configurable and never was.
  #
  # Swarm only. Docker Engine has no concept of replicas -- a second container would
  # need its own name -- so the changeset rejects anything above 1 when Engine is the
  # active orchestrator rather than accepting a number that silently does nothing.
  def change do
    alter table(:deployments) do
      add :replicas_override, :integer
    end
  end
end
