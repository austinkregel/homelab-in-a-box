defmodule Homelab.Deployments.ReleaseSteps.AdoptVolume do
  @moduledoc """
  Phase-2 step: (re)register the managed device-bind volumes over each preserve
  target's permanent home, immediately before the cutover.

  Phase 1 (`MigrateCopy`) already copied the data into the permanent home and
  registered the volumes, but this step re-asserts them so a partial rollback or
  re-run leaves a consistent set of managed volumes. It is **fail-closed**: a
  permanent home that no verified copy ever wrote aborts rather than silently
  mounting an empty volume over the cutover.

  `compensate/2` de-registers only the volumes this step created — it NEVER
  touches bytes (mirrors `MigrateCopy`).

  ## Why the precondition is read off the release, not off the filesystem

  This step used to gate on `File.dir?(backing_dir)`, and that check was asking
  the wrong machine. `MigrateCopy` writes the permanent home through
  `ContainerCopyEngine`, whose helper container mounts the destination with
  `HostConfig.Binds` — so the daemon creates the directory, **on the host**, and
  fills it. The plane itself runs containerized, where that host path does not
  exist. So phase 2 aborted on a directory phase 1 had just created and
  checksummed, and adoption could not complete on any containerized install
  (`{:backing_dir_missing, "gluetun", "/root/homelab-managed/gluetun/gluetun"}`).

  The fix is not to drop the gate. `phases(:in_place, ...)` plans no
  `adopt_volume` at all, so this step runs **only** after a `migrate_volume`, and
  the question it must answer is "did that copy actually land in the home I am
  about to register?" — which the release already records. `MigrateCopy` persists
  one `"migrated"` entry per target carrying the `"dest"` it wrote, and that
  entry only exists because the copy engine's helper container checksummed `/src`
  against `/dest` **inside the daemon** and matched. That is the same authority
  that created the directory, and it is strictly stronger evidence than an
  existence bit: an empty directory auto-created by any earlier `Binds` mount
  passes `File.dir?/1` and has no `"migrated"` entry.

  It fails closed on both of the things a real check has to catch:

    * the copy step never ran (no completed `:migrate_volume` on this release);
    * the copy went somewhere else — `managed_root` edited between the phases
      would otherwise register a volume over a directory nothing wrote to.

  A daemon-side `test -d` in a throwaway container was the other candidate and is
  worse on every axis: it costs an image pull and a container round-trip per run,
  it cannot use `Binds` to reach the path (a `Binds` source is auto-created, so
  the check would create what it is checking), and it still only proves the
  directory exists rather than that the operator's bytes are in it.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments.PermanentHome

  @impl true
  def run(step, ctx) do
    migrated = migrated_homes(ctx)

    step
    |> preserve_targets()
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      service = target["name"]
      container_path = target["container_path"]
      dir = PermanentHome.backing_dir(service, container_path)

      cond do
        not MapSet.member?(migrated, dir) ->
          Logger.error("[adopt_volume] no verified copy recorded for #{service} at #{dir}")
          {:halt, {:error, {:copy_unverified, service, dir}}}

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

  # The permanent homes a COMPLETED `:migrate_volume` on this release reports having
  # written and verified. `ReleaseRunner` rebuilds `ctx` from a freshly loaded release
  # before every step, so the handle is the one the copy step just persisted.
  defp migrated_homes(ctx) do
    ctx
    |> Map.get(:release)
    |> release_steps()
    |> Enum.filter(&(&1.type == :migrate_volume and &1.status == :completed))
    |> Enum.flat_map(fn step -> List.wrap(Map.get(step.resource_handle || %{}, "migrated")) end)
    |> Enum.filter(&(is_map(&1) and is_binary(&1["dest"])))
    |> MapSet.new(& &1["dest"])
  end

  defp release_steps(%{steps: steps}) when is_list(steps), do: steps
  defp release_steps(_), do: []

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
