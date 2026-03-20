defmodule Homelab.Deployments do
  @moduledoc """
  Context for managing deployments.

  A deployment represents an instance of an app template running
  within a tenant's space.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Deployments.Deployment
  alias Homelab.Services.ActivityLog

  def list_deployments do
    Deployment
    |> preload([:tenant, :app_template])
    |> Repo.all()
  end

  def list_deployments_for_tenant(tenant_id) do
    Deployment
    |> where(tenant_id: ^tenant_id)
    |> preload([:app_template])
    |> Repo.all()
  end

  def list_desired_states do
    Deployment
    |> where([d], d.status in [:pending, :deploying, :running, :failed])
    |> preload([:tenant, :app_template])
    |> Repo.all()
  end

  def get_deployment(id) do
    case Repo.get(Deployment, id) |> Repo.preload([:tenant, :app_template]) do
      nil -> {:error, :not_found}
      deployment -> {:ok, deployment}
    end
  end

  def get_deployment!(id) do
    Repo.get!(Deployment, id) |> Repo.preload([:tenant, :app_template])
  end

  def get_deployment_for_tenant(tenant_id, id) do
    case Deployment
         |> where(tenant_id: ^tenant_id)
         |> where([d], d.id == ^id)
         |> preload([:tenant, :app_template])
         |> Repo.one() do
      nil -> {:error, :not_found}
      deployment -> {:ok, deployment}
    end
  end

  def create_deployment(attrs) do
    %Deployment{}
    |> Deployment.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, deployment} -> {:ok, Repo.preload(deployment, [:tenant, :app_template])}
      error -> error
    end
  end

  def update_deployment(%Deployment{} = deployment, attrs) do
    deployment
    |> Deployment.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, deployment} -> {:ok, Repo.preload(deployment, [:tenant, :app_template], force: true)}
      error -> error
    end
  end

  def update_status(%Deployment{} = deployment, status, opts \\ []) do
    deployment
    |> Deployment.status_changeset(status, opts)
    |> Repo.update()
  end

  def mark_for_removal(%Deployment{} = deployment) do
    update_status(deployment, :removing)
  end

  def mark_reconciled(%Deployment{} = deployment) do
    deployment
    |> Deployment.reconciled_changeset()
    |> Repo.update()
  end

  def mark_unhealthy(external_id) do
    Deployment
    |> where(external_id: ^external_id)
    |> Repo.update_all(set: [status: :failed])
  end

  def delete_deployment(%Deployment{} = deployment) do
    Repo.delete(deployment)
  end

  def stop_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])

    if deployment.external_id do
      _ = Homelab.Config.orchestrator().undeploy(deployment.external_id)
    end

    update_deployment(deployment, %{status: :stopped, external_id: nil})
  end

  def start_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])
    orchestrator = Homelab.Config.orchestrator()

    case Homelab.Deployments.SpecBuilder.build(deployment) do
      {:ok, spec} ->
        case orchestrator.deploy(spec) do
          {:ok, external_id} ->
            update_status(deployment, :deploying, external_id: external_id)

          {:error, reason} ->
            update_status(deployment, :failed, error: inspect(reason))
        end

      {:error, reason} ->
        update_status(deployment, :failed, error: inspect(reason))
    end
  end

  def restart_deployment(%Deployment{} = deployment) do
    if deployment.external_id do
      case Homelab.Config.orchestrator().restart(deployment.external_id) do
        :ok ->
          update_status(deployment, :deploying)

        {:error, _reason} ->
          {:error, :restart_failed}
      end
    else
      {:error, :not_deployed}
    end
  end

  def destroy_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])

    if deployment.external_id do
      _ = Homelab.Config.orchestrator().undeploy(deployment.external_id)
    end

    Repo.delete(deployment)
  end

  def change_deployment(%Deployment{} = deployment, attrs \\ %{}) do
    Deployment.changeset(deployment, attrs)
  end

  @doc """
  Creates a deployment record and immediately deploys the container.
  Returns `{:ok, deployment}` on success or `{:error, reason}` on failure.
  The Docker event listener will transition status to `:running` once the
  container starts.
  """
  def deploy_now(attrs) do
    with {:ok, deployment} <- create_deployment(attrs) do
      do_deploy(deployment)
    end
  end

  defp do_deploy(deployment) do
    ensure_traefik_if_needed(deployment)

    case Homelab.Deployments.SpecBuilder.build(deployment) do
      {:ok, spec} ->
        case Homelab.Config.orchestrator().deploy(spec) do
          {:ok, external_id} ->
            ActivityLog.info("deploy", "#{deployment.app_template.name} deployed", %{
              deployment_id: deployment.id,
              external_id: external_id
            })

            {:ok, _} = update_status(deployment, :deploying, external_id: external_id)
            post_deploy_hooks(deployment)
            {:ok, get_deployment!(deployment.id)}

          {:error, reason} ->
            ActivityLog.error(
              "deploy",
              "#{deployment.app_template.name} failed: #{inspect(reason)}",
              %{deployment_id: deployment.id}
            )

            update_status(deployment, :failed, error: inspect(reason))
            {:error, reason}
        end

      {:error, reason} ->
        ActivityLog.error(
          "deploy",
          "#{deployment.app_template.name} spec build failed: #{inspect(reason)}",
          %{deployment_id: deployment.id}
        )

        update_status(deployment, :failed, error: inspect(reason))
        {:error, reason}
    end
  end

  defp ensure_traefik_if_needed(%{domain: domain}) when is_binary(domain) and domain != "" do
    case Homelab.Infrastructure.ensure_traefik() do
      {:ok, :already_running} ->
        :ok

      {:ok, :started} ->
        ActivityLog.info("infrastructure", "Traefik started")

      {:error, reason} ->
        ActivityLog.error("infrastructure", "Traefik failed: #{inspect(reason)}")
    end
  end

  defp ensure_traefik_if_needed(_deployment), do: :ok

  defp post_deploy_hooks(%{domain: domain} = deployment)
       when is_binary(domain) and domain != "" do
    exposure = deployment.app_template.exposure_mode || :public

    case Homelab.Networking.get_domain_by_fqdn(domain) do
      {:ok, _existing} ->
        :ok

      {:error, :not_found} ->
        case Homelab.Networking.create_domain(%{
               fqdn: domain,
               deployment_id: deployment.id,
               exposure_mode: exposure,
               tls_status: :pending
             }) do
          {:ok, _} ->
            ActivityLog.info("domain", "Created domain record for #{domain}", %{
              deployment_id: deployment.id
            })

          {:error, reason} ->
            ActivityLog.error(
              "domain",
              "Failed to create domain for #{domain}: #{inspect(reason)}",
              %{deployment_id: deployment.id}
            )
        end
    end

    create_dns_records(deployment)
  end

  defp post_deploy_hooks(_deployment), do: :ok

  defp create_dns_records(%{domain: domain} = deployment)
       when is_binary(domain) and domain != "" do
    ip_config = detect_ip_config()

    case Homelab.Networking.ensure_deployment_dns_records(deployment, ip_config) do
      {:ok, records} when records != [] ->
        ActivityLog.info("dns", "Created #{length(records)} DNS record(s) for #{domain}", %{
          deployment_id: deployment.id
        })

      {:ok, _} ->
        :ok

      {:error, reason} ->
        ActivityLog.error(
          "dns",
          "Failed to create DNS records for #{domain}: #{inspect(reason)}",
          %{deployment_id: deployment.id}
        )
    end
  end

  defp create_dns_records(_deployment), do: :ok

  defp detect_ip_config do
    internal_ip = get_host_lan_ip()
    %{internal_ip: internal_ip, public_ip: internal_ip}
  end

  defp get_host_lan_ip do
    case :inet.getifaddrs() do
      {:ok, addrs} ->
        addrs
        |> Enum.flat_map(fn {_iface, opts} ->
          opts
          |> Keyword.get_values(:addr)
          |> Enum.filter(&(tuple_size(&1) == 4))
          |> Enum.reject(&(&1 == {127, 0, 0, 1}))
        end)
        |> List.first()
        |> case do
          nil -> nil
          ip -> ip |> :inet.ntoa() |> to_string()
        end

      _ ->
        nil
    end
  end
end
