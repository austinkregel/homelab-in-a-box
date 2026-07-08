defmodule Homelab.Deployments.ReleaseSteps.AdoptVolume do
  @moduledoc """
  Phase-2 step: (re)register the managed device-bind volumes over each preserve
  target's permanent home, immediately before the cutover.

  Phase 1 (`MigrateCopy`) already copied the data into the permanent home and
  registered the volumes, but this step re-asserts them so a partial rollback or
  re-run leaves a consistent set of managed volumes. It is **fail-closed**: a
  missing backing directory (device bind won't create it) aborts rather than
  silently mounting an empty volume.

  `compensate/2` de-registers only the volumes this step created — it NEVER
  touches bytes (mirrors `MigrateCopy`).
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments.PermanentHome

  @impl true
  def run(step, _ctx) do
    targets = preserve_targets(step)

    targets
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      service = target["name"]
      container_path = target["container_path"]
      dir = PermanentHome.backing_dir(service, container_path)

      cond do
        not File.dir?(dir) ->
          {:halt, {:error, {:backing_dir_missing, service, dir}}}

        true ->
          case registrar().ensure_volume(service, container_path) do
            {:ok, vol} ->
              {:cont, {:ok, [%{"name" => vol.name, "created" => vol.created} | acc]}}

            {:error, reason} ->
              {:halt, {:error, {:adopt_volume_failed, service, reason}}}
          end
      end
    end)
    |> case do
      {:ok, volumes} -> {:ok, %{"volumes" => Enum.reverse(volumes)}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def compensate(step, _ctx) do
    for %{"name" => name, "created" => true} <- step.resource_handle["volumes"] || [] do
      registrar().remove_volume(name)
    end

    :ok
  end

  defp preserve_targets(step) do
    step.resource_handle
    |> Map.get("targets", [])
    |> Enum.filter(&(to_string(&1["tier"]) == "preserve"))
  end

  defp registrar, do: Application.get_env(:homelab, :migrate_volume_registrar, PermanentHome)
end
