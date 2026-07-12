defmodule Homelab.Repo.Migrations.AddVolumesOverrideToDeployments do
  use Ecto.Migration

  # Per-deployment volumes (NULL = inherit the app_template's).
  #
  # Volumes were a property of the CATALOG ENTRY only: SpecBuilder.build_volumes/2 read
  # `template.volumes` and never looked at the deployment, and the Volumes tab was a
  # read-only table of the same list. So an app that needed durable storage its template
  # did not declare had no way to get it -- you had to edit the catalog entry, which is
  # shared by every deployment of that app.
  #
  # aut.hair needs a storage volume its template never declared.
  #
  # NULL rather than [] so "inherit" stays distinguishable from "deliberately none" --
  # the same distinction ports_override draws, and getting it wrong there is what
  # silently repointed Traefik at port 80.
  def change do
    alter table(:deployments) do
      add :volumes_override, {:array, :map}
    end
  end
end
