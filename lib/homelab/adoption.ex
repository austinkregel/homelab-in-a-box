defmodule Homelab.Adoption do
  @moduledoc """
  Inventory and optional import of legacy bind-mount homelab apps (§B).
  Does not modify production paths unless the user explicitly clicks Import.
  """

  @default_threshold_bytes 1_073_741_824

  def source_root do
    System.get_env("HOMELAB_ADOPTION_SOURCE_ROOT") ||
      Homelab.Settings.get("adoption.source_root") ||
      Path.join(System.user_home!(), "homelab/appdata")
  end

  def threshold_bytes do
    case Homelab.Settings.get("adoption.import_threshold_bytes") do
      nil -> @default_threshold_bytes
      s when is_binary(s) -> String.to_integer(s)
      n when is_integer(n) -> n
    end
  end

  @doc "Path to a legacy app directory under source_root (for restic bind-mount backups)."
  def legacy_appdata_path(app_slug) do
    Path.join(source_root(), app_slug)
  end

  def classify(size_bytes) when is_integer(size_bytes) do
    if size_bytes <= threshold_bytes(), do: :auto_importable, else: :manual_only
  end

  def list_adopted_apps do
    alias Homelab.Adoption.AdoptedApp
    alias Homelab.Repo

    AdoptedApp |> Repo.all() |> Enum.sort_by(& &1.slug)
  end
end
