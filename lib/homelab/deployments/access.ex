defmodule Homelab.Deployments.Access do
  @moduledoc """
  Single source of truth for a deployment's **access model** — how it's reached.

  One choice per deployment, stored in `exposure_mode` (with the per-deployment
  `exposure_mode_override` winning):

    * **Reverse proxy** — reached via Traefik at a `domain`, with an auth level:
      `:public` (none), `:sso_protected` (SSO), `:private` (IP allowlist). Never
      binds a host port.
    * **Host ports** (`:host`) — binds the published container ports to the host.
      Never proxied.
    * **Host network** (`:host_network`) — the container shares the HOST's network
      namespace (`--network host`). Every port it listens on is already on the host,
      so nothing is mapped and nothing is published. Never proxied.
    * **Internal only** (`:service`) — no external access.

  Proxy XOR host: a deployment is reached exactly one way, so there are no silent
  overrides (a domain can't suppress a host port) and a protected app can't be
  reached on the host bypassing its auth.

  `:host_network` is exclusive for a harder reason than policy — the daemon enforces
  it. A container in the host's namespace has no address of its own on any bridge or
  overlay, so it cannot be attached to another network at all, and Traefik's Docker
  provider has no backend IP to route to. There is no configuration in which host
  networking and a proxy route coexist.
  """

  alias Homelab.Deployments.Deployment
  alias Homelab.Deployments.RuntimeSpec

  @proxy_modes [:public, :sso_protected, :private]

  # What both drivers hardcoded before a restart policy could be chosen at all.
  @default_restart_policy "on-failure"

  # UI metadata: top-level access choices and the proxy auth sub-choices.
  @access_choices [
    {"proxy", "Reverse proxy", "Served via Traefik at a domain"},
    {"host", "Host ports", "Bind container ports to the host"},
    {"host_network", "Host network", "Share the host's network namespace"},
    {"internal", "Internal only", "No external access"}
  ]
  @auth_choices [
    {"public", "None", "Anyone with the domain"},
    {"sso_protected", "SSO", "Requires login"},
    {"private", "Private", "LAN / IP allowlist"}
  ]

  @doc "The effective exposure atom (override wins over the template default)."
  def effective_exposure(%Deployment{exposure_mode_override: override, app_template: template}) do
    case override do
      m when m in [nil, ""] -> template.exposure_mode
      s -> String.to_existing_atom(s)
    end
  end

  @doc """
  The effective container image (override wins; nil = inherit the template).

  The image used to come from the template ONLY, which meant the version a deployment
  ran was decided once and never again — and editing the template to change it moved
  every other tenant's deployment of that app at the same time.
  """
  def effective_image(%Deployment{image_override: nil, app_template: template}),
    do: template.image

  def effective_image(%Deployment{image_override: image}), do: image

  @doc """
  True when this deployment runs something other than its template's image.

  The UI needs to distinguish "pinned to a version" from "following the catalog", and
  the drivers need it to decide whether a failed pull may fall back to a local image:
  an operator who named a ref wants THAT ref, never a stale local one.
  """
  def image_overridden?(%Deployment{image_override: nil}), do: false
  def image_overridden?(%Deployment{}), do: true

  @doc "Effective ports (override wins; nil = inherit the template)."
  def effective_ports(%Deployment{ports_override: nil, app_template: template}),
    do: template.ports || []

  def effective_ports(%Deployment{ports_override: ports}), do: ports

  @doc """
  The transport protocol of a single port map, normalized to `"tcp"` or `"udp"`.

  Every port map in the system is read through here rather than by reaching for
  `p["protocol"]` directly, because the key is genuinely absent on most of them: it
  postdates every template seeded, imported, or adopted before UDP support existed.
  An absent protocol is TCP — that is what those ports have always been published as,
  so defaulting anywhere else would silently re-point live deployments at a socket
  nothing is listening on.

  Anything unrecognized also falls back to TCP. A port map is operator-editable JSON
  with no schema behind it, and a typo'd protocol should publish the port the way it
  always was rather than fail the deploy.
  """
  def port_protocol(port) when is_map(port) do
    case port["protocol"] || port[:protocol] do
      p when is_binary(p) ->
        case String.downcase(String.trim(p)) do
          "udp" -> "udp"
          _ -> "tcp"
        end

      _ ->
        "tcp"
    end
  end

  @doc "True when a port map is UDP. Convenience over `port_protocol/1`."
  def udp?(port) when is_map(port), do: port_protocol(port) == "udp"

  @doc """
  Effective volumes (override wins; nil = inherit the template).

  Volumes used to come from the template ONLY, so an app that needed durable storage its
  catalog entry never declared had no way to get it — short of editing the catalog entry,
  which every deployment of that app shares.
  """
  def effective_volumes(%Deployment{volumes_override: nil, app_template: template}),
    do: template.volumes || []

  def effective_volumes(%Deployment{volumes_override: volumes}), do: volumes

  @doc "Effective resource limits map (override wins; nil = inherit the template)."
  def effective_resource_limits(%Deployment{resource_limits_override: nil, app_template: t}),
    do: t.resource_limits || %{}

  def effective_resource_limits(%Deployment{resource_limits_override: limits}), do: limits

  @doc "Effective healthcheck map (override wins; nil = inherit the template)."
  def effective_health_check(%Deployment{health_check_override: nil, app_template: t}),
    do: t.health_check || %{}

  def effective_health_check(%Deployment{health_check_override: hc}), do: hc

  @doc """
  Effective restart policy (nil = the platform default).

  Not an inherited value: there is no template field for it. Before this was settable
  both drivers hardcoded `on-failure` with three attempts, so that stays the default.
  """
  def effective_restart_policy(%Deployment{restart_policy_override: nil}),
    do: @default_restart_policy

  def effective_restart_policy(%Deployment{restart_policy_override: policy}), do: policy

  @doc "Effective replica count (nil = 1). Swarm only; Engine has no replicas."
  def effective_replicas(%Deployment{replicas_override: nil}), do: 1
  def effective_replicas(%Deployment{replicas_override: replicas}), do: replicas

  @doc """
  Effective command (override wins; nil = inherit the template).

  `[]` is a real value, not an absent one — it means "run no command", distinct from
  "run whatever the template says". Same for `effective_entrypoint/1`, where an empty
  list clears the image's own entrypoint.
  """
  def effective_command(%Deployment{command_override: nil, app_template: t}), do: t.command
  def effective_command(%Deployment{command_override: command}), do: command

  @doc "Effective entrypoint (override wins; nil = inherit the template)."
  def effective_entrypoint(%Deployment{entrypoint_override: nil, app_template: t}),
    do: t.entrypoint

  def effective_entrypoint(%Deployment{entrypoint_override: entrypoint}), do: entrypoint

  @doc "Effective network aliases (override wins; nil = inherit the template)."
  def effective_network_aliases(%Deployment{network_aliases_override: nil, app_template: t}),
    do: t.network_aliases || []

  def effective_network_aliases(%Deployment{network_aliases_override: aliases}), do: aliases

  @doc """
  Effective added capabilities (override wins; nil = inherit the template).

  Normalized on the way out so the drivers never see two spellings of one permission —
  a template carrying `CAP_NET_ADMIN` and an override carrying `net_admin` are the same
  capability, and the daemon would be handed both.
  """
  def effective_capabilities_add(%Deployment{capabilities_add_override: nil, app_template: t}),
    do: RuntimeSpec.parse_capabilities(t.capabilities_add)

  def effective_capabilities_add(%Deployment{capabilities_add_override: caps}),
    do: RuntimeSpec.parse_capabilities(caps)

  @doc "Effective dropped capabilities (override wins; nil = inherit the template)."
  def effective_capabilities_drop(%Deployment{capabilities_drop_override: nil, app_template: t}),
    do: RuntimeSpec.parse_capabilities(t.capabilities_drop)

  def effective_capabilities_drop(%Deployment{capabilities_drop_override: caps}),
    do: RuntimeSpec.parse_capabilities(caps)

  @doc "Effective device passthrough (override wins; nil = inherit the template)."
  def effective_devices(%Deployment{devices_override: nil, app_template: t}),
    do: RuntimeSpec.parse_devices(t.devices)

  def effective_devices(%Deployment{devices_override: devices}),
    do: RuntimeSpec.parse_devices(devices)

  @doc "Effective sysctls (override wins; nil = inherit the template)."
  def effective_sysctls(%Deployment{sysctls_override: nil, app_template: t}),
    do: RuntimeSpec.parse_sysctls(t.sysctls)

  def effective_sysctls(%Deployment{sysctls_override: sysctls}),
    do: RuntimeSpec.parse_sysctls(sysctls)

  def proxy_mode?(%Deployment{} = d), do: effective_exposure(d) in @proxy_modes
  def host_mode?(%Deployment{} = d), do: effective_exposure(d) == :host
  def host_network_mode?(%Deployment{} = d), do: effective_exposure(d) == :host_network
  def internal_mode?(%Deployment{} = d), do: effective_exposure(d) == :service

  @doc """
  True when this deployment lives in ANOTHER deployment's network namespace.

  Not an exposure mode: a tunneled app is still reached the normal way (a Traefik route
  at a domain, or not at all) — the labels for that route are just emitted onto its
  donor, which is the thing with an IP. What it does rule out is host ports and host
  networking, which `Netns` refuses at save time. See `Homelab.Deployments.Netns`.
  """
  defdelegate netns_child?(deployment), to: Homelab.Deployments.Netns, as: :child?

  def proxy_modes, do: @proxy_modes
  def access_choices, do: @access_choices
  def auth_choices, do: @auth_choices

  @doc ~S"""
  Top-level access key (`"proxy" | "host" | "host_network" | "internal"`) for an
  exposure value.
  """
  def access_of(exposure) do
    case to_atom(exposure) do
      :host -> "host"
      :host_network -> "host_network"
      :service -> "internal"
      _ -> "proxy"
    end
  end

  @doc "Auth key for a proxy exposure value (\"public\" by default)."
  def auth_of(exposure) do
    case to_string(exposure) do
      a when a in ~w(public sso_protected private) -> a
      _ -> "public"
    end
  end

  @doc """
  Maps a UI `(access, auth)` pair to the stored `exposure_mode` string.
  Auth only applies to proxy access.
  """
  def exposure_for("host", _auth), do: "host"
  def exposure_for("host_network", _auth), do: "host_network"
  def exposure_for("internal", _auth), do: "service"
  def exposure_for("proxy", auth) when auth in ~w(public sso_protected private), do: auth
  def exposure_for("proxy", _auth), do: "public"

  defp to_atom(v) when is_atom(v), do: v
  defp to_atom(v) when is_binary(v) and v != "", do: String.to_existing_atom(v)
  defp to_atom(_), do: nil
end
