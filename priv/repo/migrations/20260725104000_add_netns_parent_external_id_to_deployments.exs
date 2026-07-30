defmodule Homelab.Repo.Migrations.AddNetnsParentExternalIdToDeployments do
  use Ecto.Migration

  # WHICH container id this child was actually created against (NULL = not a child, or
  # never deployed).
  #
  # `network_parent_id` says which DEPLOYMENT owns the namespace; this says which
  # CONTAINER, and the two drift apart the moment the donor is re-created. That drift is
  # not cosmetic: a child whose NetworkMode names a container that no longer exists
  # cannot be started by Docker at all, so it is dead until re-created — and nothing
  # about its own row looks wrong.
  #
  # Recorded at deploy time rather than inspected per reconcile tick. The reconciler
  # runs this comparison for every child on every pass; making it a column compare keeps
  # that free, where a container inspect per child would not be.
  def change do
    alter table(:deployments) do
      add :netns_parent_external_id, :string
    end
  end
end
