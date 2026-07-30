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
    # Kernel privileges the app needs to work AT ALL, and whether it can host other
    # containers' networking. A VPN client with neither is not a degraded VPN client —
    # it cannot open a tunnel, so listing it without these is listing something that
    # does not work. Only a hand-curated catalog can know them; a registry cannot.
    capabilities_add: [],
    capabilities_drop: [],
    devices: [],
    sysctls: %{},
    netns_donor_kind: nil,
    alt_sources: [],
    stars: 0,
    pulls: 0,
    official?: false,
    deprecated?: false,
    auth_required?: false
  ]
end
