defmodule Homelab.Repo.Migrations.AddNetworkAliasesOverrideToDeployments do
  use Ecto.Migration

  # Extra names this container answers to on its network (NULL = inherit the template).
  #
  # Aliases were writable by adoption only, and adoption is exactly where they get
  # guessed: it copies the original's compose service name so siblings holding
  # `DB_HOST=mysql` keep resolving it. When that guess is wrong or incomplete, the
  # stack's internal DNS is broken and there was no way to fix it -- the failure is
  # silent, since a sibling just gets a connection error naming a host you cannot edit.
  def change do
    alter table(:deployments) do
      add :network_aliases_override, {:array, :string}
    end
  end
end
