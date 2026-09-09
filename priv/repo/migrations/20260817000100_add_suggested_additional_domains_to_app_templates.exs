defmodule Homelab.Repo.Migrations.AddSuggestedAdditionalDomainsToAppTemplates do
  use Ecto.Migration

  # A template's SUGGESTION for the extra hostnames a deployment of it usually needs --
  # the catalog-side companion to `deployments.additional_domains`. Matrix/Synapse is why:
  # the homeserver answers on `matrix.<domain>`, but it only becomes usable once the apex
  # serves `/.well-known/matrix/*` (so user ids read `@you:<domain>`), and an operator
  # cannot be expected to know that delegation trick. The template carries the row so the
  # deploy wizard can pre-fill it.
  #
  # Each entry mirrors an additional-domain: %{"host" => "", "path_prefix" =>
  # "/.well-known/matrix", "port" => nil}. `host` is left blank because the apex is
  # operator-specific -- it is resolved from the primary domain they type at deploy time
  # (matrix.example.com -> example.com), not baked into the shared template.
  def change do
    alter table(:app_templates) do
      add :suggested_additional_domains, {:array, :map}, default: [], null: false
    end
  end
end
