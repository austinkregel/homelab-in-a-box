defmodule Homelab.Deployments.Findings do
  @moduledoc """
  Everything the Settings editor can tell an operator about a configuration, in one
  pass, each answer carrying what it will actually cost them.

  The page used to state these as prose scattered through the form — a warning beside
  the publish checkbox, another under the routes list, a third in the netns callout.
  All of them rendered identically, so "the daemon will refuse this save", "this saves
  but the spec drops it", "this saves and then fails at three in the morning" and "here
  is how the default was picked" were the same yellow box. An operator had no way to
  tell which one they had to act on.

  ## Severities

    * `:refuse` — the changeset rejects the save. Nothing is written.
    * `:drop` — the save succeeds and the spec builder omits the part described.
    * `:broken` — the save succeeds, the spec keeps it, and it fails at runtime.
    * `:note` — no consequence; states a decision the page made on its own.

  Every rule here restates one the backend already enforces, and names the module that
  enforces it. A finding with no such owner would be this page's opinion rather than a
  prediction, which is how a warning ends up outliving the rule it described.
  """

  alias Homelab.Deployments.SettingsForm

  @type severity :: :refuse | :drop | :broken | :note
  @type t :: %{severity: severity(), key: String.t(), text: String.t()}

  @doc "Every finding for a form, most severe first."
  def for_form(%SettingsForm{} = form) do
    []
    |> protocol_findings(form)
    |> binding_findings(form)
    |> replica_findings(form)
    |> namespace_findings(form)
    |> route_findings(form)
    |> health_findings(form)
    |> Enum.sort_by(&severity_rank(&1.severity))
  end

  @doc "Only the findings about ports, routes and namespaces."
  def network(%SettingsForm{} = form) do
    Enum.reject(for_form(form), &(&1.key in health_keys()))
  end

  @doc "Only the findings about the healthcheck."
  def health(%SettingsForm{} = form) do
    Enum.filter(for_form(form), &(&1.key in health_keys()))
  end

  defp health_keys, do: ["Health check probes :80", "Probe target is inferred"]

  defp severity_rank(:refuse), do: 0
  defp severity_rank(:drop), do: 1
  defp severity_rank(:broken), do: 2
  defp severity_rank(:note), do: 3

  # ------------------------------------------------------------------
  # Protocol vs routing — Traefik's http services speak TCP only
  # ------------------------------------------------------------------

  defp protocol_findings(acc, form) do
    udp_proxied =
      for port <- form.ports, port["protocol"] == "udp", port["exposure"] == "proxy" do
        finding(
          :broken,
          "UDP cannot be proxied",
          "Port :#{port["internal"]} is UDP. The proxy's http services speak TCP only, " <>
            "so a route here has no usable backend."
        )
      end

    udp_routed =
      for route <- SettingsForm.live_routes(form),
          port = find_port(form, route["port"]),
          port && port["protocol"] == "udp" do
        finding(
          :broken,
          "Route points at a UDP port",
          "#{route["host"]}#{route["path_prefix"] || "/"} forwards to :#{port["internal"]}, " <>
            "which is UDP. Every request fails."
        )
      end

    acc ++ Enum.uniq(udp_proxied ++ udp_routed)
  end

  defp find_port(form, port) do
    Enum.find(form.ports, &(to_string(&1["internal"]) == to_string(port)))
  end

  # ------------------------------------------------------------------
  # Host bindings
  # ------------------------------------------------------------------

  # Two ports asking for one host binding. The daemon refuses the second, and the
  # container never starts — so this is worth catching before the save rather than in
  # the deploy log.
  defp binding_findings(acc, %{namespace: "host"} = _form), do: acc

  defp binding_findings(acc, form) do
    collisions =
      form.ports
      |> Enum.filter(&(&1["exposure"] == "host" and present?(&1["internal"])))
      |> Enum.group_by(&binding_key/1)
      |> Enum.filter(fn {_key, ports} -> length(ports) > 1 end)
      |> Enum.map(fn {key, ports} ->
        listed = Enum.map_join(ports, " and ", &":#{&1["internal"]}")

        finding(
          :broken,
          "Two ports, one host binding",
          "#{listed} both publish to #{key}. The daemon refuses the second binding."
        )
      end)

    guarded =
      form.ports
      |> Enum.filter(&SettingsForm.guarded?(form, &1))
      |> Enum.map(fn port ->
        finding(
          :drop,
          "Binding dropped",
          "#{auth_word(form)} applies per route, so a host binding on :#{port["internal"]} " <>
            "would answer with nothing in front of it. SpecBuilder.build_ports/1 drops it " <>
            "on save."
        )
      end)

    tls =
      if form.auth == "public" and Enum.any?(form.ports, &(&1["exposure"] == "host")) do
        [
          finding(
            :note,
            "No TLS on a published port",
            "A published port answers plain TCP on the host — no certificate, none of " <>
              "the proxy's headers. That is what you want for SSH; rarely for HTTP."
          )
        ]
      else
        []
      end

    acc ++ collisions ++ guarded ++ tls
  end

  defp binding_key(port) do
    "#{port["host_ip"] || "0.0.0.0"}:#{blank(port["external"], port["internal"])}/#{port["protocol"]}"
  end

  defp auth_word(%{auth: "private"}), do: "The IP allowlist"
  defp auth_word(_form), do: "SSO"

  # ------------------------------------------------------------------
  # Replicas — every one of these is an Ecto refusal, not a warning
  # ------------------------------------------------------------------

  defp replica_findings(acc, form) do
    case parse_int(form.replicas) do
      count when is_integer(count) and count > 1 ->
        acc ++ replica_conflicts(form) ++ [swarm_note()]

      _one ->
        acc ++ sticky_note(form)
    end
  end

  defp replica_conflicts(%{namespace: "host"}) do
    [
      finding(
        :refuse,
        "Replicas need a namespace of their own",
        "Every task would bind the same host ports, and all but one would restart-loop."
      )
    ]
  end

  defp replica_conflicts(%{namespace: "donor"}) do
    [
      finding(
        :refuse,
        "Replicas cannot share a namespace",
        "Every task would join the donor's namespace and collide identically. " <>
          "Netns.validate_changeset/1 refuses this."
      )
    ]
  end

  defp replica_conflicts(form) do
    if Enum.any?(form.ports, &(&1["exposure"] == "host")) do
      [
        finding(
          :refuse,
          "Replicas cannot bind host ports",
          "Each task would bind the same host port."
        )
      ]
    else
      []
    end
  end

  defp swarm_note do
    finding(
      :note,
      "Replicas need Swarm",
      "Docker Engine runs one container; a count above 1 is rejected rather than " <>
        "silently ignored."
    )
  end

  defp sticky_note(%{sticky: true}) do
    [
      finding(
        :note,
        "Sticky does nothing at one replica",
        "There is only one container to pin a client to."
      )
    ]
  end

  defp sticky_note(_form), do: []

  # ------------------------------------------------------------------
  # Namespace vs network identity
  # ------------------------------------------------------------------

  defp namespace_findings(acc, %{namespace: "donor"} = form) do
    aliases =
      if present?(form.aliases) do
        [
          finding(
            :refuse,
            "Network aliases need an endpoint",
            "A container in another's namespace has no endpoint to register a name on."
          )
        ]
      else
        []
      end

    acc ++
      aliases ++
      [
        finding(
          :note,
          "Publishing unavailable",
          "The daemon rejects port bindings alongside a container network mode. These " <>
            "ports answer on the donor's address, and siblings reach them on localhost."
        ),
        finding(
          :note,
          "Saving recreates the group",
          "The containers behind this one are pinned to a specific container id, so the " <>
            "whole namespace stack goes round together."
        )
      ]
  end

  defp namespace_findings(acc, %{namespace: "host"}) do
    acc ++
      [
        finding(
          :note,
          "No address of its own",
          "Nothing is mapped and there is no bridge IP for the proxy to route to. Every " <>
            "port below is already a host port."
        ),
        finding(
          :note,
          "Port conflicts stop the container",
          "A port already bound on the host keeps this container from starting."
        )
      ]
  end

  defp namespace_findings(acc, _form), do: acc

  # ------------------------------------------------------------------
  # Routes
  # ------------------------------------------------------------------

  defp route_findings(acc, %{namespace: "host"}), do: acc

  defp route_findings(acc, form) do
    routes = SettingsForm.live_routes(form)

    # Multi-homing a VPN client onto the proxy network is what broke a real stack, and
    # nothing on the form said it was happening. A warning rather than a refusal:
    # reaching a VPN client's own control UI is a real thing to want, just not what
    # most people typing a hostname here mean.
    donor_route =
      if is_binary(form.donor_kind) and routes != [] do
        [
          finding(
            :note,
            "This is a network container",
            "A route here reaches this container itself rather than anything running " <>
              "inside its network, and attaches it to the proxy network as a second " <>
              "interface its firewall was not told about. The deployments sharing its " <>
              "network carry their own routes, served from this container's address."
          )
        ]
      else
        []
      end

    unreachable =
      for port <- form.ports,
          port["exposure"] == "proxy",
          not SettingsForm.routed?(form, port["internal"]) do
        finding(
          :note,
          "Nothing routes here",
          ":#{port["internal"]} is set to proxied, but no route points at it."
        )
      end

    backend =
      if routes != [] and not Enum.any?(form.ports, &(&1["exposure"] == "proxy")) do
        [
          finding(
            :broken,
            "No backend",
            "No port is set to Proxied, so these routes reach nothing."
          )
        ]
      else
        []
      end

    acc ++ donor_route ++ unreachable ++ backend
  end

  # ------------------------------------------------------------------
  # Health check
  # ------------------------------------------------------------------

  defp health_findings(acc, %{health: %{"mode" => "path"} = health} = form) do
    if present?(health["path"]) do
      case SettingsForm.probe_port(form) do
        {_port, :fallback} ->
          acc ++
            [
              finding(
                :broken,
                "Health check probes :80",
                "No TCP port is declared, so the probe falls back to localhost:80" <>
                  "#{health["path"]} — nothing listens there, and the container never " <>
                  "turns healthy."
              )
            ]

        {port, :guess} ->
          acc ++
            [
              finding(
                :note,
                "Probe target is inferred",
                "No route names a port, so the probe uses the first web-role TCP port, " <>
                  ":#{port}."
              )
            ]

        {_port, :route} ->
          acc
      end
    else
      acc
    end
  end

  defp health_findings(acc, _form), do: acc

  # ------------------------------------------------------------------

  defp finding(severity, key, text), do: %{severity: severity, key: key, text: text}

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp blank(value, fallback) do
    if present?(to_string(value)), do: value, else: fallback
  end

  defp parse_int(value) do
    case value |> to_string() |> Integer.parse() do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end
end
