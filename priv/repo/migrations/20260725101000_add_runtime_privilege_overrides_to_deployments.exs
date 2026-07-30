defmodule Homelab.Repo.Migrations.AddRuntimePrivilegeOverridesToDeployments do
  use Ecto.Migration

  # Per-deployment kernel privileges (NULL = inherit the app_template's).
  #
  # These are per-DEPLOYMENT and not template-only for the same reason the command
  # override exists: a shared catalog template cannot know that this particular
  # instance is the one wired to the USB dongle on this particular host, and an
  # operator correcting a captured-from-adoption device path must not rewrite the
  # template every other deployment inherits.
  #
  # NULL and [] mean different things, which is why neither array column defaults:
  # NULL inherits the template, [] is "explicitly none" -- and explicitly dropping a
  # capability the template adds is a real hardening instruction, not an absent value.
  def change do
    alter table(:deployments) do
      add :capabilities_add_override, {:array, :string}
      add :capabilities_drop_override, {:array, :string}
      add :devices_override, {:array, :map}
      add :sysctls_override, :map
    end
  end
end
