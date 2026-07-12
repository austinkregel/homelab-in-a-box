defmodule Homelab.Deployments.ReleaseSteps.AdoptContainer do
  @moduledoc """
  The cutover: replace the original (unmanaged) container with a managed one that
  serves the SAME data, without ever removing the original.

  `run/2`:

    1. **Final re-quiesce** of the original — records its restart policy, disables
       it, and stops the container. This closes the write-divergence window left
       open by `:resume_old` (which brought the original back up after phase-1's
       copy) and prevents a port conflict / double-writer during cutover.
    2. **Verified delta re-sync** — re-copies each preserve target into its
       permanent home via the same checksum-proving copy engine, so the managed
       data matches the original *as of its stopped state*.
    3. **Imports the original's host port bindings** into `ports_override`.
    4. **Deploys the managed replacement** from `SpecBuilder.build/1`, merging the
       decrypted (adopted) secrets into its env, and persists the new
       `external_id`.

  `compensate/2` undeploys the replacement, resets the row, and **resumes the
  original** with its recorded restart policy — leaving it serving exactly as
  before. The original container is never removed here or anywhere in the saga.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.{PermanentHome, Releases, SpecBuilder}
  alias Homelab.Deployments.Migrate.{ContainerControl, LocalCopyEngine}

  @deployable_from [:pending, :deploying, :failed, :stopped]

  @impl true
  def run(step, ctx) do
    old = step.resource_handle["container"]
    targets = preserve_targets(step)
    deployment = Deployments.get_deployment!(ctx.deployment.id)

    with {:ok, policy} <- ops().restart_policy(old),
         :ok <- ops().set_restart_policy(old, "no"),
         :ok <- ops().stop(old, stop_timeout()),
         :ok <- delta_resync(targets),
         :ok <- import_ports(deployment, old) do
      deployment = Deployments.get_deployment!(deployment.id)

      with {:ok, spec} <- SpecBuilder.build(deployment) do
        spec = %{spec | env: Map.merge(spec.env, Releases.decrypted_secrets(deployment.id))}

        case orchestrator().deploy(spec) do
          {:ok, new_id} ->
            Deployments.transition_status(deployment, :deploying, @deployable_from,
              external_id: new_id
            )

            Logger.info("[adopt_container] cut #{deployment.id} over to #{new_id}")

            {:ok,
             %{
               "kind" => "container",
               "external_id" => new_id,
               "deployment_id" => deployment.id,
               "container" => old,
               "original_restart_policy" => policy
             }}

          {:error, reason} ->
            {:error, {:adopt_deploy_failed, deployment.id, reason}}
        end
      end
    else
      {:error, reason} -> {:error, {:adopt_container_failed, old, reason}}
    end
  end

  @impl true
  def compensate(step, _ctx) do
    handle = step.resource_handle

    if is_binary(handle["external_id"]) do
      _ = orchestrator().undeploy(handle["external_id"])

      case Deployments.get_deployment(handle["deployment_id"]) do
        {:ok, deployment} ->
          Deployments.update_deployment(deployment, %{status: :stopped, external_id: nil})

        _ ->
          :ok
      end
    end

    # Resume the original exactly as it was — never remove it.
    if is_binary(handle["container"]) do
      _ = ops().set_restart_policy(handle["container"], handle["original_restart_policy"] || "no")
      _ = ops().start(handle["container"])
    end

    :ok
  end

  # --- internals ------------------------------------------------------------

  # An in-place target was never copied anywhere: the managed container mounts the
  # ORIGINAL directory. There is no permanent home to re-sync into, and "migrating" it
  # would copy the directory onto itself.
  defp delta_resync(targets) do
    targets
    |> Enum.reject(&(to_string(&1["strategy"]) == "in_place"))
    |> Enum.reduce_while(:ok, fn target, :ok ->
      dest = PermanentHome.backing_dir(target["name"], target["container_path"])

      case engine().migrate(target["source"], dest, []) do
        {:ok, _proof} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:delta_resync_failed, target["name"], reason}}}
      end
    end)
  end

  defp import_ports(deployment, old) do
    case ops().port_bindings(old) do
      {:ok, [_ | _] = bindings} ->
        case Deployments.update_deployment(deployment, %{ports_override: bindings}) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:ports_import_failed, reason}}
        end

      _ ->
        :ok
    end
  end

  defp preserve_targets(step) do
    step.resource_handle
    |> Map.get("targets", [])
    |> Enum.filter(&(to_string(&1["tier"]) == "preserve"))
  end

  defp ops, do: Application.get_env(:homelab, :container_ops, ContainerControl)
  defp engine, do: Application.get_env(:homelab, :migrate_copy_engine, LocalCopyEngine)
  defp stop_timeout, do: Application.get_env(:homelab, :quiesce_stop_timeout, 60)
  defp orchestrator, do: Homelab.Config.orchestrator()
end
