defmodule Homelab.Behaviours.ApplicationCatalog do
  @moduledoc """
  Behaviour for curated application catalogs.

  Application catalogs are directories of recommended container images
  maintained by communities or organizations (e.g. LinuxServer.io, Hotio).
  They don't host images themselves — they reference images on registries
  like Docker Hub or GHCR.

  Each driver must declare its identity via `driver_id/0`, `display_name/0`,
  and `description/0`.
  """

  @callback driver_id() :: String.t()
  @callback display_name() :: String.t()
  @callback description() :: String.t()

  @callback browse(opts :: keyword()) ::
              {:ok, [Homelab.Catalog.CatalogEntry.t()]} | {:error, term()}
  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [Homelab.Catalog.CatalogEntry.t()]} | {:error, term()}
  @callback app_details(name :: String.t()) ::
              {:ok, Homelab.Catalog.CatalogEntry.t()} | {:error, term()}

  @optional_callbacks [app_details: 1]
end
