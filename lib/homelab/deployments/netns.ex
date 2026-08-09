defmodule Homelab.Deployments.Netns do
  @moduledoc """
  Sharing one network namespace between deployments — the `network_mode: service:x`
  shape, which is how a VPN'd stack is actually built.

  A **donor** is a deployment that owns a network namespace. A **child** names it in
  `network_parent_id` and has no network stack of its own: the daemon is told
  `NetworkMode: "container:<donor external id>"`, and from that moment the child has
  the donor's interfaces, the donor's routing table, the donor's firewall and the
  donor's IP. Its only route out is whatever the donor provides — which for gluetun is
  the tunnel, and nothing else.

  ## What a child gives up, and why each is enforced rather than ignored

    * **Its own ports.** There is no mapping to make; the child listens on the donor's
      stack. `PortBindings` alongside a container network mode is rejected by the daemon
      ("conflicting options: port publishing and the container type network mode").
    * **Its own networks.** `/networks/<n>/connect` fails with the same error host
      networking gets ("container sharing network namespace with another container or
      host cannot be connected to any other network"), so a child is never multi-homed
      and never joins ingress.
    * **Its own DNS name.** No endpoint, no embedded-DNS record. Siblings reach each
      other on `localhost`, which is also why two children cannot both want port 8080.
    * **Replicas.** Every task would join the same namespace and collide identically.

  ## Why routing goes on the DONOR

  Traefik's Docker provider resolves a backend by the container's IP on a named
  network. A child has no endpoint anywhere, so there is nothing for Traefik to
  discover — exactly the problem `host_network` has, and the reason that mode is
  exclusive with the proxy modes.

  The way out is that the child's ports ARE the donor's ports: reaching the donor's IP
  on port 8989 reaches the child listening there. So the child's Traefik labels are
  emitted onto the DONOR, which is multi-homed onto the ingress network for exactly
  this reason, and `SpecBuilder` builds them per child.

  The cost is a cascade, and it is deliberate: a donor re-create mints a new container
  id, and every child's `NetworkMode` still names the old one. Docker will not restart
  such a container at all, so a route change on any child re-creates the donor and
  every child with it. `Deployments.redeploy_netns_stack/1` is that operation, and
  `Reconciler` catches the case where it did not happen.

  ## Depth 1 only

  Docker permits chains (A joins B joins C). This does not: the staleness cascade
  becomes a graph walk, and a re-create in the middle silently orphans everything
  downstream. One donor, N children, no grandchildren.
  """

  import Ecto.Changeset
  import Ecto.Query

  # Shadows Elixir's own `Access`, which is deliberate here — every use in this module is
  # the deployment access model, and the kernel one is never wanted.
  alias Homelab.Deployments.Access
  alias Homelab.Deployments.Deployment
  alias Homelab.Repo

  @doc "True when this deployment lives in another deployment's network namespace."
  def child?(%Deployment{network_parent_id: nil}), do: false
  def child?(%Deployment{network_parent_id: _id}), do: true

  @doc """
  The deployments living in this one's namespace, ordered, with their templates.

  `SpecBuilder` needs the template to know each child's declared ports, and needs the
  whole set because the donor's labels are the union of its children's routes.

  Prefers an already-preloaded `:network_children` — including an explicit `[]`, which
  is a caller stating this deployment has none — and falls back to a query. A miss here
  would silently drop a child's ONLY route, so not-loaded means look it up rather than
  assume nothing.
  """
  def children(%Deployment{network_children: children}) when is_list(children), do: children
  def children(%Deployment{id: nil}), do: []

  def children(%Deployment{id: id}) do
    Deployment
    |> where([d], d.network_parent_id == ^id)
    |> order_by([d], asc: d.id)
    |> preload([:app_template, :tenant])
    |> Repo.all()
  end

  @doc "The deployment whose namespace this one lives in, or nil."
  def donor(%Deployment{network_parent_id: nil}), do: nil

  def donor(%Deployment{network_parent: %Deployment{} = parent}), do: parent

  def donor(%Deployment{network_parent_id: parent_id}) do
    Deployment
    |> where([d], d.id == ^parent_id)
    |> preload([:app_template, :tenant])
    |> Repo.one()
  end

  @doc "True when anything is living in this deployment's namespace."
  def donor?(%Deployment{id: nil}), do: false

  def donor?(%Deployment{id: id}) do
    Repo.exists?(from d in Deployment, where: d.network_parent_id == ^id)
  end

  @doc """
  The `NetworkMode` a child's container must be created with.

  Nil when the donor has no container yet — the caller must fail rather than guess,
  because a create with a stale or absent id produces a container that can never start.
  """
  def network_mode(%Deployment{external_id: nil}), do: nil
  def network_mode(%Deployment{external_id: id}), do: "container:#{id}"

  @doc """
  True when a child was created against a donor container that is no longer the donor's.

  This is the failure the cascade exists to prevent. The donor was re-created out from
  under the child, so the child's `NetworkMode` names a container id that is gone —
  Docker will not start it at all ("cannot join network of a non running container"),
  and nothing about the child's own row looks wrong. Without this check the app is down
  permanently with an error pointing at the wrong thing.

  Compares recorded ids rather than inspecting the container: this runs for every child
  on every reconcile pass, and a per-child inspect would not be free.

  Not stale when either id is missing — a child that has never been deployed, or a donor
  with no container yet, is a state the release saga owns, not a drift to correct.
  """
  def stale?(%Deployment{netns_parent_external_id: nil}, _donor), do: false
  def stale?(_child, nil), do: false
  def stale?(_child, %Deployment{external_id: nil}), do: false

  def stale?(%Deployment{netns_parent_external_id: recorded}, %Deployment{external_id: current}),
    do: recorded != current

  @doc """
  Every child that can no longer start because its donor was re-created.

  Preloaded with the donor so a caller can report which container went missing.
  """
  def stale_children do
    Deployment
    |> where([d], not is_nil(d.network_parent_id) and not is_nil(d.netns_parent_external_id))
    |> preload([:app_template, :network_parent])
    |> Repo.all()
    |> Enum.filter(&stale?(&1, &1.network_parent))
  end

  @doc """
  Every container port this deployment is known to listen on.

  The union of the explicit routed port, the extra-route ports and the template's
  declared ports. Used for the sibling-collision check: children of one donor share a
  single localhost, so two apps that both listen on 8080 is not a preference conflict —
  the second one to start fails to bind, and which one that is depends on scheduling.
  """
  def declared_ports(%Deployment{} = deployment) do
    # Through `Access.effective_ports/1`, NOT off the template directly: reading the
    # template ignores `ports_override`, which is what the wizard, the Ports tab and
    # adoption all write. A child whose port was corrected in the UI would derive its
    # donor's firewall rule from the ORIGINAL port — and the readiness check, reading the
    # same stale list, would agree that the route was fine.
    template_ports =
      case deployment.app_template do
        %{ports: _ports} -> Enum.flat_map(Access.effective_ports(deployment), &port_of/1)
        _ -> []
      end

    extra_ports =
      deployment.extra_routes
      |> List.wrap()
      |> Enum.flat_map(&port_of/1)

    ([deployment.routed_port] ++ extra_ports ++ template_ports)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp port_of(%{"port" => port}), do: to_port(port)
  defp port_of(%{"internal" => port}), do: to_port(port)
  defp port_of(%{"container" => port}), do: to_port(port)
  defp port_of(%{port: port}), do: to_port(port)
  defp port_of(_row), do: []

  defp to_port(port) when is_integer(port), do: [port]

  defp to_port(port) when is_binary(port) do
    case Integer.parse(String.trim(port)) do
      {n, ""} -> [n]
      _ -> []
    end
  end

  defp to_port(_port), do: []

  @doc """
  Validates a deployment's namespace membership.

  Everything here is refused rather than repaired, because each failure mode is silent:
  the daemon rejects some of these with a message naming a flag the operator never
  typed, and simply does the wrong thing with the rest.
  """
  def validate_changeset(changeset) do
    case get_field(changeset, :network_parent_id) do
      nil ->
        changeset

      parent_id ->
        changeset
        |> validate_supported_orchestrator()
        |> validate_not_self(parent_id)
        |> validate_exclusive_with_host_modes()
        |> validate_no_own_network_identity()
        |> then(fn cs -> if parent_error?(cs), do: cs, else: validate_parent(cs, parent_id) end)
    end
  end

  # Swarm has no namespace sharing at all: `ServiceSpec` cannot express it, and there is
  # no partial version of this to fall back to. Refuse where the choice is made.
  defp validate_supported_orchestrator(changeset) do
    if Homelab.Config.orchestrator() == Homelab.Orchestrators.DockerSwarm do
      add_error(
        changeset,
        :network_parent_id,
        "Docker Swarm cannot share a network namespace between services — this needs the " <>
          "Docker Engine orchestrator"
      )
    else
      changeset
    end
  end

  defp validate_not_self(changeset, parent_id) do
    if get_field(changeset, :id) == parent_id do
      add_error(changeset, :network_parent_id, "cannot route through itself")
    else
      changeset
    end
  end

  # Both are namespace choices, and a container has exactly one namespace. `:host` is
  # excluded for a second reason: a child cannot bind a host port, so choosing it would
  # produce an access mode that silently does nothing.
  #
  # Reads the EFFECTIVE exposure, not the raw override. Adoption writes exposure onto the
  # TEMPLATE (`AdoptionPlanner` sets `exposure_mode: :host`), leaving the override nil —
  # so a guard that only inspects the override is blind for exactly the deployments most
  # likely to be host-mode.
  defp validate_exclusive_with_host_modes(changeset) do
    case changeset_exposure(changeset) do
      "host_network" ->
        add_error(
          changeset,
          :network_parent_id,
          "cannot be combined with host networking — a container has one network namespace"
        )

      "host" ->
        add_error(
          changeset,
          :network_parent_id,
          "cannot be combined with host ports — a container in another's namespace has no " <>
            "ports of its own to bind"
        )

      _ ->
        changeset
    end
  end

  defp validate_no_own_network_identity(changeset) do
    changeset
    |> then(fn cs ->
      case get_field(cs, :replicas_override) do
        n when is_integer(n) and n > 1 ->
          add_error(
            cs,
            :replicas_override,
            "cannot be used while routing through another container — every task would " <>
              "join the same namespace and collide"
          )

        _ ->
          cs
      end
    end)
    |> then(fn cs ->
      case get_field(cs, :network_aliases_override) do
        aliases when is_list(aliases) and aliases != [] ->
          add_error(
            cs,
            :network_aliases_override,
            "cannot be set while routing through another container — it has no network " <>
              "endpoint to register a name on"
          )

        _ ->
          cs
      end
    end)
  end

  defp validate_parent(changeset, parent_id) do
    case Repo.get(Deployment, parent_id) |> preload_parent() do
      nil ->
        add_error(changeset, :network_parent_id, "does not exist")

      parent ->
        # Short-circuited, not accumulated. These checks are not independent — a
        # deployment pointed at itself is ALSO pointed at something that is already a
        # child, and reporting both makes the operator read two contradictory
        # explanations of one mistake. The first one is the one that is actually wrong.
        [
          &validate_parent_same_tenant(&1, parent),
          &validate_parent_is_not_itself_a_child(&1, parent),
          &validate_parent_can_donate(&1, parent),
          &validate_no_sibling_port_collision(&1, parent)
        ]
        |> Enum.reduce(changeset, fn validate, acc ->
          if parent_error?(acc), do: acc, else: validate.(acc)
        end)
    end
  end

  defp parent_error?(changeset), do: Keyword.has_key?(changeset.errors, :network_parent_id)

  defp preload_parent(nil), do: nil
  defp preload_parent(parent), do: Repo.preload(parent, [:app_template])

  # A tenant network is the isolation boundary. Joining a namespace across it would put
  # one tenant's traffic inside another's, which no amount of network policy undoes.
  defp validate_parent_same_tenant(changeset, parent) do
    if get_field(changeset, :tenant_id) == parent.tenant_id do
      changeset
    else
      add_error(changeset, :network_parent_id, "must be in the same space")
    end
  end

  defp validate_parent_is_not_itself_a_child(changeset, %{network_parent_id: nil}), do: changeset

  defp validate_parent_is_not_itself_a_child(changeset, _parent) do
    add_error(
      changeset,
      :network_parent_id,
      "already routes through another container — chains are not supported, point at the " <>
        "container that owns the namespace instead"
    )
  end

  defp validate_parent_can_donate(changeset, parent) do
    if to_string(Access.effective_exposure(parent)) == "host_network" do
      add_error(
        changeset,
        :network_parent_id,
        "uses host networking, so it has no namespace of its own to share"
      )
    else
      changeset
    end
  end

  # Children of one donor share a single localhost. Two apps that both listen on 8080 is
  # not a preference conflict: the second to start fails to bind, and which one that is
  # depends on scheduling order, so the stack works until it does not.
  defp validate_no_sibling_port_collision(changeset, parent) do
    own_id = get_field(changeset, :id)
    own_ports = MapSet.new(changeset_ports(changeset))

    occupied =
      [parent | children(parent)]
      |> Enum.reject(&(&1.id == own_id))
      |> Enum.flat_map(fn sibling -> Enum.map(declared_ports(sibling), &{&1, sibling}) end)
      |> Map.new()

    case Enum.filter(occupied, fn {port, _sibling} -> MapSet.member?(own_ports, port) end) do
      [] ->
        changeset

      collisions ->
        detail =
          Enum.map_join(collisions, ", ", fn {port, sibling} ->
            "#{port} (#{sibling_name(sibling)})"
          end)

        add_error(
          changeset,
          :network_parent_id,
          "these ports are already in use inside that container's network: #{detail}"
        )
    end
  end

  defp changeset_ports(changeset) do
    declared_ports(%Deployment{
      routed_port: get_field(changeset, :routed_port),
      extra_routes: get_field(changeset, :extra_routes) || [],
      app_template: changeset_template(changeset)
    })
  end

  @doc """
  The exposure this deployment will actually run with: the override when set, the
  template's default otherwise.

  Same resolution `Access.effective_exposure/1` does, but driven off a CHANGESET that may
  not have its template loaded — which is what every save-time guard has to work from.
  Public because `Deployment.validate_scalable/2` needs the identical answer.
  """
  def effective_exposure_for_changeset(changeset), do: changeset_exposure(changeset)

  defp changeset_exposure(changeset) do
    case get_field(changeset, :exposure_mode_override) do
      value when value not in [nil, ""] ->
        value

      _ ->
        case changeset_template(changeset) do
          %{exposure_mode: mode} when not is_nil(mode) -> to_string(mode)
          _ -> nil
        end
    end
  end

  # Read off the struct rather than through `get_field/2`: an unloaded association makes
  # `get_field` RAISE ("attempting to cast or change association ... that was not
  # loaded"), and every caller that updates a deployment fetched without a preload would
  # blow up inside validation.
  defp changeset_template(changeset) do
    case changeset.data.app_template do
      %Homelab.Catalog.AppTemplate{} = template ->
        template

      _ ->
        case get_field(changeset, :app_template_id) do
          nil -> nil
          id -> Repo.get(Homelab.Catalog.AppTemplate, id)
        end
    end
  end

  defp sibling_name(%Deployment{app_template: %{name: name}}) when is_binary(name), do: name
  defp sibling_name(%Deployment{id: id}), do: "deployment #{id}"
end
