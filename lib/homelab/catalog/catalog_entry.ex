defmodule Homelab.Catalog.CatalogEntry do
  @moduledoc "Universal struct for catalog entries from registries and application catalogs."

  @type t :: %__MODULE__{}

  defstruct [
    :name,
    :namespace,
    :description,
    :logo_url,
    :version,
    :source,
    :full_ref,
    :project_url,
    :setup_url,
    categories: [],
    architectures: [],
    required_ports: [],
    required_volumes: [],
    default_env: %{},
    required_env: [],
    alt_sources: [],
    stars: 0,
    pulls: 0,
    official?: false,
    deprecated?: false,
    auth_required?: false
  ]
end
