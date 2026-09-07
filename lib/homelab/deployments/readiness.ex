defmodule Homelab.Deployments.Readiness do
  @moduledoc """
  Production-readiness checklist for a deployment — the "bridge from iterating
  quickly to production-ready."

  Each gate is computed purely from the deployment, its template, its backup jobs and
  the deployments sharing its network namespace, and reports `:pass` or `:gap` with a
  human detail and the deployment tab where it's addressed. The checklist is advisory:
  it surfaces the gap between a fast-iteration deploy (internal/host, no auth, no
  backups) and a production one (reverse-proxy + TLS, auth, verified backups, health
  + limits).

  No gate inspects a running container: one that did could not answer while the
  container it describes is restarting, which is when it is most worth asking.
  """

  alias Homelab.Deployments.{Access, Deployment, DeploymentSecret, Netns, SpecBuilder}
  alias Homelab.Backups
  alias Homelab.Repo

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

  # Two sides of one arrangement, and a deployment is on at most one of them — chains are
  # refused. On neither side, there is nothing here to ask.
  defp netns_checks(%Deployment{network_parent_id: nil} = deployment) do
    # `children/1` rather than `Netns.donor?/1`: the donor gates need the set anyway, and
    # an empty list is the same answer one query earlier.
    case Netns.children(deployment) do
      [] -> []
      children -> donor_checks(deployment, children)
    end
  end

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
           "#{deployment_name(donor)} was re-created, so this container is pinned to a container " <>
             "that no longer exists and cannot start. Re-deploy the group."}

        running? ->
          {true, "Routing all traffic through #{deployment_name(donor)}."}

        true ->
          {false,
           "#{deployment_name(donor)} is #{donor.status} — this container has no network until it runs."}
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
          "#{deployment_name(donor)} lets #{Enum.join(ports, ", ")} in.",
          "settings"
        )

      true ->
        missing = Enum.reject(ports, &(&1 in allowed))

        check(
          :netns_firewall,
          "Reachable through the tunnel",
          false,
          "#{deployment_name(donor)}'s firewall does not allow #{Enum.join(missing, ", ")}, so a " <>
            "request to those ports is dropped with no error. Re-deploy #{deployment_name(donor)} " <>
            "to apply the derived rules, or set FIREWALL_INPUT_PORTS by hand.",
          "settings"
        )
    end
  end

  # -- Donor gates --

  # A donor is never a child, so the gates above never reach it — yet it is the deployment
  # whose failure takes every container in the namespace down with it.
  defp donor_checks(donor, children) do
    [
      donor_privileges_check(donor),
      donor_firewall_check(donor, children),
      donor_tunnel_health_check(donor),
      donor_own_route_check(donor),
      donor_vpn_provider_check(donor)
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Every gate below is knowledge about a VPN client, so none of it is imposed on a donor
  # that never claimed to be one.
  defp tunnel_donor?(%Deployment{app_template: %{netns_donor_kind: kind}})
       when is_binary(kind) and kind != "",
       do: true

  defp tunnel_donor?(_donor), do: false

  # Narrower still, for the gates that read gluetun's own variable names.
  defp gluetun_donor?(%Deployment{app_template: %{netns_donor_kind: "gluetun"}}), do: true
  defp gluetun_donor?(_donor), do: false

  # A tunnel client denied either of these fails closed: it starts, stays up, and carries
  # nothing. Adoption drops both when the original's `HostConfig` is not carried across.
  defp donor_privileges_check(donor) do
    if tunnel_donor?(donor) do
      net_admin? = "NET_ADMIN" in Access.effective_capabilities_add(donor)
      tun? = tun_device?(Access.effective_devices(donor))

      detail =
        cond do
          net_admin? and tun? ->
            "Granted NET_ADMIN and /dev/net/tun, so it can raise the tunnel and hold the " <>
              "kill-switch."

          not net_admin? and not tun? ->
            "Has neither NET_ADMIN nor /dev/net/tun, so it cannot raise a tunnel at all — it " <>
              "starts, stays up, and every container in its namespace has no route out."

          not net_admin? ->
            "Has /dev/net/tun but not NET_ADMIN, so it cannot install its routes or its " <>
              "kill-switch rules — it starts, stays up, and carries nothing."

          true ->
            "Has NET_ADMIN but not /dev/net/tun, so there is no interface to raise the tunnel " <>
              "on — it starts, stays up, and carries nothing."
        end

      check(
        :netns_donor_privileges,
        "Kernel privileges",
        net_admin? and tun?,
        detail,
        "settings"
      )
    end
  end

  # The container path, not the host one: the tunnel is opened by the process inside.
  defp tun_device?(devices), do: Enum.any?(devices, &(&1["container_path"] == "/dev/net/tun"))

  # `netns_firewall_check/2` answers this for one child; from the donor it covers all of
  # them, so it can name a blocked SIBLING that no single child's gate can see.
  defp donor_firewall_check(donor, children) do
    if gluetun_donor?(donor) do
      allowed = firewall_ports(donor, children)

      blocked =
        children
        |> Enum.map(fn child ->
          {child, Enum.reject(Netns.declared_ports(child), &(&1 in allowed))}
        end)
        |> Enum.reject(fn {_child, missing} -> missing == [] end)

      declared_any? = Enum.any?(children, &(Netns.declared_ports(&1) != []))

      {pass?, detail} =
        cond do
          blocked != [] ->
            {false,
             "The kill-switch drops #{blocked_ports(blocked)}, so a request to those ports " <>
               "gets no answer and nothing logs it. Re-deploy #{deployment_name(donor)} to apply " <>
               "the derived rules, or set FIREWALL_INPUT_PORTS by hand."}

          declared_any? ->
            {true,
             "Lets #{Enum.join(Enum.sort(allowed), ", ")} in, covering every port the " <>
               "containers in its namespace listen on."}

          true ->
            {true, "Nothing in its namespace declares a port, so there is nothing to let in."}
        end

      check(
        :netns_donor_firewall,
        "Kill-switch lets its containers in",
        pass?,
        detail,
        "environment"
      )
    end
  end

  defp blocked_ports(blocked) do
    Enum.map_join(blocked, ", ", fn {child, missing} ->
      "#{Enum.join(missing, ", ")} (#{deployment_name(child)})"
    end)
  end

  # With nothing declared, `AwaitHealth` weakens to "the process is running" — true for a
  # VPN client tens of seconds before its tunnel is. `resilience_check/1` asks the same of
  # the container itself; this asks it of the barrier every child waits on.
  defp donor_tunnel_health_check(donor) do
    if tunnel_donor?(donor) do
      declared? = SpecBuilder.declares_healthcheck?(Access.effective_health_check(donor))

      detail =
        if declared?,
          do:
            "Declares a healthcheck, so a container in its namespace waits for the tunnel " <>
              "rather than for the process.",
          else:
            "Declares no healthcheck, so the barrier every container in its namespace waits " <>
              "on releases the moment the process starts — well before the tunnel is up. " <>
              "Declare one so the wait means what it says."

      check(:netns_donor_health, "Tunnel readiness", declared?, detail, "settings")
    end
  end

  # A tunnel client binds its kill-switch to the interface it found at startup, so an extra
  # way in is an extra chance it bound to the wrong one. Only the donor's OWN route is
  # asked about — its children's routes are emitted onto it and cannot be given up.
  defp donor_own_route_check(donor) do
    if tunnel_donor?(donor) do
      routed? =
        Access.proxy_mode?(donor) and is_binary(donor.domain) and donor.domain != ""

      detail =
        if routed?,
          do:
            "Carries a route of its own at #{donor.domain}, which its namespace does not " <>
              "need — the containers inside are already reached through the routes this one " <>
              "carries for them. It is one more way in on a container that binds its " <>
              "kill-switch to whichever interface it found at startup, and bound to the " <>
              "wrong one that firewall drops the tunnel's own traffic. Move the route onto " <>
              "a container in the namespace, or clear the domain.",
          else:
            "No route of its own — it carries only the routes of the containers in its " <>
              "namespace."

      check(:netns_donor_route, "Route of its own", not routed?, detail, "settings")
    end
  end

  # Gluetun reads `OPENVPN_CUSTOM_CONFIG` only when the provider is `custom`; named beside
  # any other it silently dials that provider's built-in server list instead.
  defp donor_vpn_provider_check(donor) do
    env = configured_env(donor)
    provider = env["VPN_SERVICE_PROVIDER"]

    cond do
      not gluetun_donor?(donor) ->
        nil

      # With no custom config named there is no question, rather than a passing answer.
      blank?(env["OPENVPN_CUSTOM_CONFIG"]) ->
        nil

      # A provider arriving as a secret is merged over the readable value and cannot be
      # read back, so the answer is unknown rather than a gap.
      blank?(provider) or secret_key?(donor, "VPN_SERVICE_PROVIDER") ->
        nil

      String.downcase(String.trim(provider)) == "custom" ->
        check(
          :netns_donor_vpn_config,
          "VPN provider matches its config",
          true,
          "Dials the server named in its custom OpenVPN config.",
          "environment"
        )

      true ->
        check(
          :netns_donor_vpn_config,
          "VPN provider matches its config",
          false,
          "Names a custom OpenVPN config while VPN_SERVICE_PROVIDER is \"#{provider}\", so " <>
            "the config's remote line is ignored and the built-in server list for " <>
            "#{provider} is dialled instead. The tunnel comes up either way and nothing " <>
            "reports the difference. Set VPN_SERVICE_PROVIDER to \"custom\", or remove " <>
            "OPENVPN_CUSTOM_CONFIG.",
          "environment"
        )
    end
  end

  # The two layers of `SpecBuilder.build_env/5` that are stored in the clear: the
  # template's defaults with the operator's overrides on top.
  defp configured_env(%Deployment{app_template: %{default_env: defaults}, env_overrides: env}),
    do: Map.merge(defaults || %{}, env || %{})

  defp configured_env(%Deployment{env_overrides: env}), do: env || %{}

  # Whether a key's value arrives as a secret, and is therefore not readable above. Only
  # the key is read — nothing here decrypts a value in order to render a gate.
  defp secret_key?(%Deployment{secrets: secrets}, key) when is_list(secrets),
    do: Enum.any?(secrets, &(&1.key == key))

  defp secret_key?(%Deployment{id: nil}, _key), do: false

  defp secret_key?(%Deployment{id: id}, key),
    do: Repo.get_by(DeploymentSecret, deployment_id: id, key: key) != nil

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

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
  #
  # The children are passed in so that both views of the firewall derive from the same
  # group rather than from two lookups that can disagree.
  defp firewall_ports(donor), do: firewall_ports(donor, Netns.children(donor))

  defp firewall_ports(donor, children) do
    derived =
      SpecBuilder.donor_env(donor.app_template, donor.tenant, children)
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

  defp deployment_name(%Deployment{app_template: %{name: name}}) when is_binary(name), do: name
  defp deployment_name(%Deployment{id: id}), do: "deployment #{id}"

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
