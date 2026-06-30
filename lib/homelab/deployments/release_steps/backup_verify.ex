defmodule Homelab.Deployments.ReleaseSteps.BackupVerify do
  @moduledoc """
  The fail-closed backup gate. For every `:preserve` target of a release, it
  produces a backup AND proves it restorable before the saga is allowed to touch
  the live data. If any target's backup or verification fails, the step returns
  `{:error, ...}` and the runner rolls the release back — nothing destructive runs
  without a verified copy in hand.

  Targets are read from the step's `resource_handle["targets"]` (set at plan time
  from `Homelab.Deployments.AdoptionDiscovery`): a list of
  `%{"name" =>, "path" =>, "tier" =>}`. Only `preserve` targets are backed up —
  `rebuildable` repopulates itself and `out_of_scope` isn't ours.

  Strategy is pluggable (`config :homelab, :backup_strategy`), defaulting to
  `Homelab.Deployments.Backups.FileCopy`. A DB target will later resolve to a
  logical-dump strategy; the gate contract (backup + verify) is identical.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments.Backups.FileCopy

  @impl true
  def run(step, ctx) do
    targets = preserve_targets(step)
    root = Path.join(backup_root(), backup_id(step, ctx))

    Logger.info("[backup_verify] #{length(targets)} preserve target(s) -> #{root}")

    case backup_all(targets, root) do
      {:ok, artifacts} ->
        {:ok, %{"verified" => true, "root" => root, "backups" => artifacts}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def compensate(step, _ctx) do
    # Backups are copies, never the source — safe to remove on rollback.
    case step.resource_handle do
      %{"root" => root} when is_binary(root) ->
        File.rm_rf(root)
        :ok

      _ ->
        :ok
    end
  end

  # --- internals ------------------------------------------------------------

  defp backup_all(targets, root) do
    targets
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {target, idx}, {:ok, acc} ->
      dest = Path.join(root, slug(target, idx))
      strategy = strategy_for(target)
      source = target["path"]

      with {:ok, artifact} <- strategy.backup(source, dest, []),
           :ok <- strategy.verify(artifact, []) do
        {:cont, {:ok, [Map.put(artifact, "target", target["name"]) | acc]}}
      else
        {:error, reason} ->
          Logger.error("[backup_verify] FAILED for #{target["name"]} (#{inspect(reason)})")
          {:halt, {:error, {:backup_verify_failed, target["name"], reason}}}
      end
    end)
    |> case do
      {:ok, artifacts} -> {:ok, Enum.reverse(artifacts)}
      {:error, _} = err -> err
    end
  end

  defp preserve_targets(step) do
    step.resource_handle
    |> Map.get("targets", [])
    |> Enum.filter(&(to_string(&1["tier"]) == "preserve"))
  end

  defp strategy_for(_target), do: Application.get_env(:homelab, :backup_strategy, FileCopy)

  defp backup_root do
    Application.get_env(:homelab, :backup_root, Path.join(System.tmp_dir!(), "homelab_backups"))
  end

  defp backup_id(step, ctx) do
    deployment_id = ctx |> Map.get(:deployment) |> id_of()
    release_id = ctx |> Map.get(:release) |> id_of()

    cond do
      deployment_id && release_id -> "#{deployment_id}-release-#{release_id}"
      release_id -> "release-#{release_id}"
      true -> "step-#{step.id}"
    end
  end

  defp id_of(nil), do: nil
  defp id_of(%{id: id}), do: id
  defp id_of(_), do: nil

  defp slug(target, idx) do
    base = target["name"] || "target"
    safe = String.replace(to_string(base), ~r/[^A-Za-z0-9_.-]/, "_")
    "#{idx}-#{safe}"
  end
end
