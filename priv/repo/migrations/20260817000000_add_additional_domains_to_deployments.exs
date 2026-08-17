defmodule Homelab.Repo.Migrations.AddAdditionalDomainsToDeployments do
  use Ecto.Migration

  # Additional HOST routes for one deployment -- the mirror of `extra_routes`.
  #
  # `extra_routes` sends a second PATH on the same host to a second port. This sends a
  # second HOST to the same container. Matrix/Synapse is why the routing model needed
  # both: the homeserver answers on `matrix.example.com`, but the delegation files that
  # make user ids read `@you:example.com` have to be served from the APEX --
  # `example.com/.well-known/matrix/*` -- without handing the rest of the apex to Synapse.
  #
  # Each entry: %{"host" => "example.com", "path_prefix" => "/.well-known/matrix", "port" => nil}.
  # `path_prefix` scopes the host to a path (leaving the rest of that host free); `port`
  # names a distinct backend (e.g. a sibling app inside a shared gluetun netns) and falls
  # back to the deployment's routed port. Both are optional; only `host` is required.
  def change do
    alter table(:deployments) do
      add :additional_domains, {:array, :map}, default: [], null: false
    end
  end
end
