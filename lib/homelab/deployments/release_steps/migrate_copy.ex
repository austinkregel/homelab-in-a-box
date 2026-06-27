defmodule Homelab.Deployments.ReleaseSteps.MigrateCopy do
  @moduledoc """
  Phase-1 migration step: for each `:preserve` target, copy its data from the
  original location into its permanent home and register the managed volume —
  fail-closed on any copy/verify error.

  Per target it:

    1. Copies `source -> PermanentHome.backing_dir(service, container_path)` via
       the configured `Migrate.CopyEngine`, which also PROVES the copy is
       byte-identical to the original (the user's "confirm copy == original").
    2. Registers the device-bind managed volume over that directory via the
       configured `Migrate.VolumeRegistrar`.

  The original is never touched — it stays as the rollback until the operator
  confirms the permanent home is healthy. On rollback, `compensate/2` removes the
  copies and the volumes this step created (never the source).

  Targets come from `step.resource_handle["targets"]`: a list of
  `%{"name", "source", "container_path", "tier"}` produced by discovery. Only
  `preserve` targets are migrated.

  Configurable: `:migrate_copy_engine` (default `Migrate.LocalCopyEngine`),
  `:migrate_volume_registrar` (default `PermanentHome`).
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments.PermanentHome
  alias Homelab.Deployments.Migrate.LocalCopyEngine

  @impl true
  def run(step, _ctx) do
    targets = preserve_targets(step)
    Logger.info("[migrate_copy] migrating #{length(targets)} preserve target(s)")

    case migrate_all(targets) do
      {:ok, migrated} -> {:ok, %{"verified" => true, "migrated" => migrated}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def compensate(step, _ctx) do
    case step.resource_handle do
      %{"migrated" => migrated} when is_list(migrated) ->
        Enum.each(migrated, fn entry ->
          if entry["created"], do: registrar().remove_volume(entry["volume"])
          if is_binary(entry["dest"]), do: File.rm_rf(entry["dest"])
        end)

        :ok

      _ ->
        :ok
    end
  end

  # --- internals ------------------------------------------------------------

  defp migrate_all(targets) do
    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      service = target["name"]
      source = target["source"]
      container_path = target["container_path"]
      dest = PermanentHome.backing_dir(service, container_path)

      with {:ok, proof} <- engine().migrate(source, dest, []),
           {:ok, vol} <- registrar().ensure_volume(service, container_path) do
        entry = %{
          "service" => service,
          "source" => source,
          "dest" => dest,
          "volume" => vol.name,
          "created" => vol.created,
          "files" => proof["files"],
          "bytes" => proof["bytes"],
          "digest" => proof["digest"]
        }

        {:cont, {:ok, [entry | acc]}}
      else
        {:error, reason} ->
          Logger.error("[migrate_copy] FAILED for #{service} (#{inspect(reason)})")
          {:halt, {:error, {:migrate_failed, service, reason}}}
      end
    end)
    |> case do
      {:ok, migrated} -> {:ok, Enum.reverse(migrated)}
      {:error, _} = err -> err
    end
  end

  defp preserve_targets(step) do
    step.resource_handle
    |> Map.get("targets", [])
    |> Enum.filter(&(to_string(&1["tier"]) == "preserve"))
  end

  defp engine, do: Application.get_env(:homelab, :migrate_copy_engine, LocalCopyEngine)
  defp registrar, do: Application.get_env(:homelab, :migrate_volume_registrar, PermanentHome)
end
