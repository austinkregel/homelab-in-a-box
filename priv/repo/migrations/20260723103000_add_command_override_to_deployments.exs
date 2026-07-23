defmodule Homelab.Repo.Migrations.AddCommandOverrideToDeployments do
  use Ecto.Migration

  # What the container RUNS, per deployment (NULL = inherit the app_template's).
  #
  # `command`/`entrypoint` existed on app_templates but only adoption and compose
  # import ever wrote them, and no UI could. An operator whose adopted service was
  # captured with the wrong command had no way to correct it, and no catalog app
  # could be given one at all.
  #
  # NULL and [] mean different things here, which is why neither column defaults:
  # NULL inherits the template, [] is "explicitly nothing" -- and an empty entrypoint
  # is a real Docker instruction (it clears the image's own), not an absent value.
  def change do
    alter table(:deployments) do
      add :command_override, {:array, :string}
      add :entrypoint_override, {:array, :string}
    end
  end
end
