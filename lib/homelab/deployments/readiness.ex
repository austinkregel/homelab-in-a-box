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

  alias Homelab.Deployments.{Access, Deployment, Netns, SpecBuilder}
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
    ] ++ netns_checks(deployment)
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

  # Only shown for a container that shares another's network namespace — for everything
  # else these are not gaps, they are not applicable.
  defp netns_checks(%Deployment{network_parent_id: nil}), do: []

  defp netns_checks(%Deployment{} = deployment) do
    case Netns.donor(deployment) do
      nil -> []
      donor -> [netns_donor_check(deployment, donor), netns_firewall_check(deployment, donor)]
    end
  end

  # A child has no network of its own: if the donor is not running, the child is not
  # "degraded", it cannot start at all. And once the donor has been re-created, the
  # child is pinned to a container id that no longer exists — Docker refuses to start
  # it, with an error that points at the wrong thing.
  defp netns_donor_check(deployment, donor) do
    stale? = Netns.stale?(deployment, donor)
    running? = donor.status == :running

    {pass?, detail} =
      cond do
        stale? ->
          {false,
           "#{donor_name(donor)} was re-created, so this container is pinned to a container " <>
             "that no longer exists and cannot start. Re-deploy the group."}

        running? ->
          {true, "Routing all traffic through #{donor_name(donor)}."}

        true ->
          {false,
           "#{donor_name(donor)} is #{donor.status} — this container has no network until it runs."}
      end

    check(:netns_donor, "Network container", pass?, detail, "settings")
  end

  # The single most common way this arrangement fails, and the one with no error
  # message anywhere: gluetun's kill-switch drops traffic to a port it was not told
  # about, so Traefik gets a 502 and neither container logs a thing.
  defp netns_firewall_check(deployment, donor) do
    ports = Netns.declared_ports(deployment)
    allowed = firewall_ports(donor)

    cond do
      donor.app_template.netns_donor_kind != "gluetun" ->
        check(
          :netns_firewall,
          "Reachable through the tunnel",
          true,
          "No firewall rules to derive for this network container.",
          "settings"
        )

      ports == [] ->
        check(
          :netns_firewall,
          "Reachable through the tunnel",
          true,
          "No ports declared, so nothing needs to be let in.",
          "settings"
        )

      Enum.all?(ports, &(&1 in allowed)) ->
        check(
          :netns_firewall,
          "Reachable through the tunnel",
          true,
          "#{donor_name(donor)} lets #{Enum.join(ports, ", ")} in.",
          "settings"
        )

      true ->
        missing = Enum.reject(ports, &(&1 in allowed))

        check(
          :netns_firewall,
          "Reachable through the tunnel",
          false,
          "#{donor_name(donor)}'s firewall does not allow #{Enum.join(missing, ", ")}, so a " <>
            "request to those ports is dropped with no error. Re-deploy #{donor_name(donor)} " <>
            "to apply the derived rules, or set FIREWALL_INPUT_PORTS by hand.",
          "settings"
        )
    end
  end

  # The donor's effective `FIREWALL_INPUT_PORTS`: what the platform derives, with an
  # operator override on top — the same merge order `SpecBuilder.build_env/5` uses.
  #
  # This deliberately reads the CONFIGURATION rather than the deployed container. Reading
  # `env_overrides` alone (as this first did) could never see the derived value at all,
  # because deriving it means putting it in the spec's env, never in the overrides — so
  # the gate reported a permanent failure for every correctly-configured donor and told
  # the operator to re-deploy something that had already happened. A check that cannot
  # pass trains people to ignore it, and this is the one that catches a real 502.
  #
  # "Configured but not yet applied" is a different question, and `netns_donor_check/2`
  # right above already answers it via `Netns.stale?/2`.
  defp firewall_ports(donor) do
    derived =
      SpecBuilder.donor_env(donor.app_template, donor.tenant, Netns.children(donor))
      |> Map.get("FIREWALL_INPUT_PORTS", "")

    (donor.env_overrides || %{})
    |> Map.get("FIREWALL_INPUT_PORTS", derived)
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn port ->
      case Integer.parse(String.trim(port)) do
        {n, ""} -> [n]
        _ -> []
      end
    end)
  end

  defp donor_name(%Deployment{app_template: %{name: name}}) when is_binary(name), do: name
  defp donor_name(%Deployment{id: id}), do: "deployment #{id}"

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
