defmodule Homelab.Deployments.Readiness do
  @moduledoc """
  Production-readiness checklist for a deployment — the "bridge from iterating
  quickly to production-ready."

  Each gate is computed purely from the deployment, its template, and its backup
  jobs, and reports `:pass` or `:gap` with a human detail and the deployment tab
  where it's addressed. The checklist is advisory: it surfaces the gap between a
  fast-iteration deploy (internal/host, no auth, no backups) and a production one
  (reverse-proxy + TLS, auth, verified backups, health + limits).
  """

  alias Homelab.Deployments.{Access, Deployment, SpecBuilder}
  alias Homelab.Backups

  @type status :: :pass | :gap
  @type check :: %{
          key: atom(),
          title: String.t(),
          status: status(),
          detail: String.t(),
          fix_tab: String.t()
        }

  @doc "The full ordered checklist for a deployment."
  @spec checks(Deployment.t()) :: [check()]
  def checks(%Deployment{} = deployment) do
    [
      ingress_check(deployment),
      auth_check(deployment),
      backups_check(deployment),
      resilience_check(deployment)
    ]
  end

  @doc "True when every gate passes."
  @spec ready?(Deployment.t()) :: boolean()
  def ready?(%Deployment{} = deployment), do: Enum.all?(checks(deployment), &(&1.status == :pass))

  @doc "Only the gates that still need attention."
  @spec gaps(Deployment.t()) :: [check()]
  def gaps(%Deployment{} = deployment),
    do: Enum.filter(checks(deployment), &(&1.status == :gap))

  # -- Gates --

  defp ingress_check(deployment) do
    routed? =
      Access.proxy_mode?(deployment) and is_binary(deployment.domain) and deployment.domain != ""

    detail =
      if routed?,
        do: "Reverse-proxied over HTTPS at #{deployment.domain}.",
        else: "Not reachable at a domain — use reverse-proxy access and set a domain."

    check(:ingress, "Reverse proxy + TLS", routed?, detail, "settings")
  end

  defp auth_check(deployment) do
    exposure = Access.effective_exposure(deployment)
    protected? = exposure in [:sso_protected, :private]

    detail =
      if protected?,
        do: "Protected by #{auth_word(exposure)}.",
        else: "No authentication — require SSO or restrict access to the LAN."

    check(:auth, "Authentication", protected?, detail, "settings")
  end

  defp backups_check(deployment) do
    jobs = Backups.list_backup_jobs_for_deployment(deployment.id)
    verified? = Enum.any?(jobs, &(&1.status == :completed))

    detail =
      cond do
        verified? -> "A backup has completed successfully."
        jobs != [] -> "Backup configured, but no successful run yet."
        true -> "No backups configured."
      end

    check(:backups, "Backups", verified?, detail, "backups")
  end

  defp resilience_check(deployment) do
    health? = SpecBuilder.declares_healthcheck?(Access.effective_health_check(deployment))
    limits = Access.effective_resource_limits(deployment)
    limited? = is_number(limits["memory_mb"]) and is_number(limits["cpu_shares"])

    detail =
      cond do
        health? and limited? -> "Healthcheck declared with memory/cpu limits."
        not health? and not limited? -> "No healthcheck and no resource limits set."
        not health? -> "Resource limits set, but no healthcheck declared."
        true -> "Healthcheck declared, but no explicit resource limits."
      end

    check(:resilience, "Health & limits", health? and limited?, detail, "settings")
  end

  # -- Helpers --

  defp check(key, title, pass?, detail, fix_tab) do
    %{
      key: key,
      title: title,
      status: if(pass?, do: :pass, else: :gap),
      detail: detail,
      fix_tab: fix_tab
    }
  end

  defp auth_word(:sso_protected), do: "SSO"
  defp auth_word(:private), do: "an IP allowlist"
  defp auth_word(_), do: "authentication"
end
