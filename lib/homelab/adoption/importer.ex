defmodule Homelab.Adoption.Importer do
  @moduledoc """
  Imports `auto_importable` apps into ZFS datasets (§B2). Requires ZFS;
  returns `{:error, :storage_unavailable}` until the host agent is present.
  """

  alias Homelab.Adoption.AdoptedApp
  alias Homelab.Repo

  def import_app(app, opts \\ [])

  def import_app(%AdoptedApp{classification: "auto_importable"} = _app, _opts) do
    if Homelab.Storage.available?() do
      {:error, :not_implemented}
    else
      {:error, :storage_unavailable}
    end
  end

  def import_app(%AdoptedApp{}, _opts), do: {:error, :manual_only}

  def mark_imported(%AdoptedApp{} = app) do
    app
    |> AdoptedApp.changeset(%{import_status: "imported", imported_at: DateTime.utc_now()})
    |> Repo.update()
  end
end
