defmodule Homelab.Behaviours.ContainerRegistry do
  @moduledoc """
  Behaviour for container registry drivers.

  Registries are where container images are stored and pulled from
  (Docker Hub, GHCR, ECR). For curated app directories, see
  `Homelab.Behaviours.ApplicationCatalog`.
  """

  @type capability :: :search | :list_tags | :pull_auth

  @callback driver_id() :: String.t()
  @callback display_name() :: String.t()
  @callback description() :: String.t()
  @callback capabilities() :: [capability()]

  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [Homelab.Catalog.CatalogEntry.t()]} | {:error, term()}
  @callback list_tags(image :: String.t(), opts :: keyword()) ::
              {:ok, [Homelab.Catalog.TagInfo.t()]} | {:error, term()}
  @callback full_image_ref(name :: String.t(), tag :: String.t()) :: String.t()

  @callback pull_auth_config() ::
              {:ok, map()} | {:error, :not_configured}
  @callback configured?() :: boolean()

  @optional_callbacks [pull_auth_config: 0, configured?: 0]
end
