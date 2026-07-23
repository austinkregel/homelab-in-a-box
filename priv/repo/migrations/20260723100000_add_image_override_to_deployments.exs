defmodule Homelab.Repo.Migrations.AddImageOverrideToDeployments do
  use Ecto.Migration

  # Per-deployment container image (NULL = inherit the app_template's).
  #
  # The image was a property of the CATALOG ENTRY only. SpecBuilder read
  # `template.image` directly -- the one spec field with no `Access.effective_*`
  # resolver, while every field around it had one. So the version a deployment ran
  # was decided once, at first deploy, and could never be changed again.
  #
  # Editing the template was not a fix either: templates are shared (`has_many
  # :deployments`) and reused by slug, so moving one deployment to a new version
  # moved every other tenant's deployment of that app with it.
  #
  # This is a security problem, not an ergonomics one -- an app pinned to a tag with
  # a known CVE had no path off it. And the inverse: 141 of 141 curated entries use
  # `:latest`, and every config save re-pulls, so a deployment could silently cross a
  # major version while the operator was editing a port. GitLab is the case that makes
  # both halves fatal, since it requires INCREMENTAL upgrades -- skip one and the
  # install is unrecoverable.
  #
  # NULL rather than "" so "inherit the catalog default" stays distinguishable from
  # a deliberate value, the same distinction ports_override and volumes_override draw.
  def change do
    alter table(:deployments) do
      add :image_override, :string
    end
  end
end
