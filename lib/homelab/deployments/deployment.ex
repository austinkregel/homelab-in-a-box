defmodule Homelab.Deployments.Deployment do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  alias Homelab.Deployments.GpuSpec
  alias Homelab.Deployments.Netns
  alias Homelab.Deployments.RuntimeSpec
  alias Homelab.Deployments.VolumeSpec
  alias Homelab.Networking.Hostname

  @statuses [:pending, :deploying, :running, :failed, :stopped, :removing]
  # Same set as AppTemplate.exposure_mode; stored as a string override here so a
  # single deployment can diverge from the (shared) template default.
  @exposure_modes ~w(private sso_protected public service host host_network)

  # Docker Engine's `RestartPolicy.Name` vocabulary. Swarm has a narrower one
  # (`none`/`on-failure`/`any`); the driver translates rather than the operator, since
  # "restart this unless I stopped it" is the intent either way.
  @restart_policies ~w(no on-failure always unless-stopped)

  schema "deployments" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :external_id, :string
    field :domain, :string
    field :env_overrides, :map, default: %{}
    # Per-deployment overrides (nil = inherit the app_template default).
    # The image is here rather than on the template because templates are SHARED:
    # moving one deployment to a new version must not move every other tenant's.
    field :image_override, :string
    field :ports_override, {:array, :map}
    field :volumes_override, {:array, :map}
    field :exposure_mode_override, :string
    field :resource_limits_override, :map
    field :health_check_override, :map
    # nil = the platform default (on-failure, 3 attempts), which is what both drivers
    # hardcoded before this was settable at all.
    field :restart_policy_override, :string
    # Swarm only; nil = 1. Docker Engine has no replicas.
    field :replicas_override, :integer
    # nil = inherit the template. [] is NOT nil here: an empty entrypoint clears the
    # image's own, which is a real instruction rather than an absent value.
    field :command_override, {:array, :string}
    field :entrypoint_override, {:array, :string}
    field :network_aliases_override, {:array, :string}
    # Kernel privileges, per deployment (nil = inherit the template). Per-deployment
    # rather than template-only because a shared catalog template cannot know that
    # THIS instance is the one wired to the dongle on THIS host. Same nil-vs-[]
    # distinction as command/entrypoint: [] explicitly clears what the template adds.
    field :capabilities_add_override, {:array, :string}
    field :capabilities_drop_override, {:array, :string}
    field :devices_override, {:array, :map}
    field :sysctls_override, :map
    # Reverse-proxy options (sticky sessions, &c).
    field :proxy_options, :map, default: %{}
    # The container port the proxy forwards to. An explicit DECISION, never
    # inferred -- see SpecBuilder.routed_port/1. nil = fall back to the heuristic.
    field :routed_port, :integer
    # Additional path -> port routes, for an app serving a second protocol from a
    # second port (aut.hair: Laravel on 8000, Reverb websockets on 6001 at /app).
    # Each: %{"path_prefix" => "/app", "port" => 6001}.
    field :extra_routes, {:array, :map}, default: []
    # Additional HOST routes -- a second hostname (optionally path-scoped) reaching this
    # same container. The mirror of extra_routes: that is a second PATH to a second port,
    # this is a second HOST. Synapse needs it -- the homeserver answers on
    # matrix.example.com while example.com/.well-known/matrix/* serves the delegation
    # files that keep user ids as @you:example.com. Each: %{"host" => "example.com",
    # "path_prefix" => "/.well-known/matrix", "port" => nil}; path_prefix and port are
    # optional (port falls back to routed_port, e.g. a sibling app in a shared netns).
    field :additional_domains, {:array, :map}, default: []
    # The donor CONTAINER id this child was last created against. Diverges from the
    # donor's current `external_id` the moment the donor is re-created, which is the
    # only signal that a child is unstartable — see Netns.stale?/2.
    field :netns_parent_external_id, :string
    field :computed_spec, :map
    field :last_reconciled_at, :utc_datetime
    field :error_message, :string

    belongs_to :tenant, Homelab.Tenants.Tenant
    belongs_to :app_template, Homelab.Catalog.AppTemplate

    # Whose network namespace this container lives in (nil = its own). This is the
    # `network_mode: service:gluetun` shape: the child has no network stack, no ports
    # and no DNS name of its own — see Homelab.Deployments.Netns.
    belongs_to :network_parent, __MODULE__
    has_many :network_children, __MODULE__, foreign_key: :network_parent_id

    # Generated and adopted credentials, encrypted at rest. `SpecBuilder` merges these
    # into the container env; declaring the association lets it use a preloaded set and
    # fall back to a query, so a caller that has them cannot be made to deploy without.
    has_many :secrets, Homelab.Deployments.DeploymentSecret

    has_many :domains, Homelab.Networking.Domain
    has_many :dns_records, Homelab.Networking.DnsRecord
    has_many :backup_jobs, Homelab.Backups.BackupJob

    timestamps()
  end

  @required_fields ~w(tenant_id app_template_id)a
  @optional_fields ~w(status external_id domain env_overrides image_override ports_override
                      volumes_override exposure_mode_override resource_limits_override
                      health_check_override restart_policy_override replicas_override
                      command_override entrypoint_override network_aliases_override
                      capabilities_add_override capabilities_drop_override
                      devices_override sysctls_override
                      proxy_options routed_port extra_routes additional_domains
                      network_parent_id
                      netns_parent_external_id
                      computed_spec last_reconciled_at error_message)a

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:exposure_mode_override, @exposure_modes)
    |> normalize_domain()
    |> validate_domain()
    |> validate_number(:routed_port, greater_than: 0, less_than: 65_536)
    |> normalize_image_override()
    |> validate_image_override()
    |> validate_inclusion(:restart_policy_override, @restart_policies)
    |> validate_replicas()
    |> validate_extra_routes()
    |> normalize_additional_domains()
    |> validate_additional_domains()
    |> VolumeSpec.validate_changeset(:volumes_override)
    |> GpuSpec.validate_changeset(:resource_limits_override)
    |> RuntimeSpec.validate_capabilities(:capabilities_add_override)
    |> RuntimeSpec.validate_capabilities(:capabilities_drop_override, allow_all: true)
    |> RuntimeSpec.validate_devices(:devices_override)
    |> RuntimeSpec.validate_sysctls(:sysctls_override)
    |> Netns.validate_changeset()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:app_template_id)
    |> foreign_key_constraint(:network_parent_id)
    |> unique_constraint([:tenant_id, :app_template_id])
  end

  # "" is what an emptied form field posts, and it is NOT a value -- it means "go back to
  # the catalog default". Storing it would make `effective_image/1` hand the daemon a blank
  # image, so collapse it to nil, the same way a cleared ports editor means inherit.
  defp normalize_image_override(changeset) do
    case get_change(changeset, :image_override) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> put_change(changeset, :image_override, nil)
          trimmed -> put_change(changeset, :image_override, trimmed)
        end

      _ ->
        changeset
    end
  end

  # A malformed image ref does not fail here -- it fails four layers away, as a pull
  # error inside a release step, reported as a failed deployment. The operator who typed
  # it is long gone by then. Reject it in the form instead.
  defp validate_image_override(changeset) do
    case get_change(changeset, :image_override) do
      nil ->
        changeset

      ref ->
        case Homelab.Catalog.ImageRef.parse(ref) do
          {:ok, _parsed} ->
            changeset

          {:error, :invalid} ->
            add_error(changeset, :image_override, "is not a valid image reference")
        end
    end
  end

  # Scaling past one task is a Swarm capability, and an operator asking for it on Docker
  # Engine is asking for something that cannot happen. Silently running one container
  # anyway would present as "I set 3 replicas and only one is serving" -- so say no here,
  # where the number was typed, rather than dropping it inside the driver.
  #
  # Host ports and host networking are exclusive with replicas for a different reason:
  # every task would bind the same port on the same host and all but one would fail to
  # start, which Swarm reports as a task that keeps restarting rather than as a conflict.
  defp validate_replicas(changeset) do
    changeset
    |> validate_number(:replicas_override, greater_than_or_equal_to: 1)
    |> then(fn cs ->
      case get_field(cs, :replicas_override) do
        n when is_integer(n) and n > 1 -> validate_scalable(cs, n)
        _ -> cs
      end
    end)
  end

  defp validate_scalable(changeset, _replicas) do
    # The EFFECTIVE exposure, not the raw override. Adoption writes exposure onto the
    # TEMPLATE and leaves the override nil, so reading the override alone made this guard
    # blind for precisely the deployments most likely to be host-mode — and the failure it
    # exists to prevent (every task binding the same host port, all but one restart-
    # looping) is reported by Swarm as a flapping task, not as a conflict.
    exposure = Netns.effective_exposure_for_changeset(changeset)

    cond do
      Homelab.Config.orchestrator() == Homelab.Orchestrators.DockerEngine ->
        add_error(changeset, :replicas_override, "requires Docker Swarm")

      exposure in ["host", "host_network"] ->
        add_error(
          changeset,
          :replicas_override,
          "cannot be used with host ports or host networking"
        )

      true ->
        changeset
    end
  end

  @doc "All valid restart-policy values (strings)."
  def restart_policies, do: @restart_policies

  # An extra route becomes a Traefik router rule and a load-balancer port. A malformed
  # one does not fail loudly -- Traefik silently declines to route it, and the app looks
  # broken in a browser with nothing in the logs. So reject it here, where the operator
  # is still looking at the form.
  defp validate_extra_routes(changeset) do
    case get_change(changeset, :extra_routes) do
      nil ->
        changeset

      routes when is_list(routes) ->
        Enum.reduce(routes, changeset, fn route, acc ->
          cond do
            not valid_path_prefix?(route["path_prefix"]) ->
              add_error(
                acc,
                :extra_routes,
                "path must start with / (got #{inspect(route["path_prefix"])})"
              )

            not valid_port?(route["port"]) ->
              add_error(
                acc,
                :extra_routes,
                "port must be 1-65535 (got #{inspect(route["port"])})"
              )

            true ->
              acc
          end
        end)

      _ ->
        add_error(changeset, :extra_routes, "must be a list")
    end
  end

  defp valid_path_prefix?(path) when is_binary(path),
    do: String.starts_with?(path, "/") and String.trim(path) != "/"

  defp valid_path_prefix?(_path), do: false

  defp valid_port?(port) when is_integer(port), do: port > 0 and port < 65_536
  defp valid_port?(_port), do: false

  # The primary domain is interpolated straight into a Traefik `Host(...)` rule and
  # handed to Let's Encrypt as an ACME identifier, and until now it was cast as a bare
  # string with nothing checking it -- so whatever was typed became a router rule.
  #
  # Normalizing first is what makes the validation below fair: a host pasted out of a
  # browser bar (`https://matrix.example.com/`) is a hostname an operator has every
  # reason to expect to work, and rejecting it for punctuation they cannot see is worse
  # than accepting it. What is STORED is the canonical form, so the label the driver
  # emits and the identifier ACME orders are the same string.
  defp normalize_domain(changeset) do
    case get_change(changeset, :domain) do
      value when is_binary(value) -> put_change(changeset, :domain, Hostname.normalize(value))
      _ -> changeset
    end
  end

  # `communication.ventures,matrix.communication.ventures` is the value that made this
  # necessary. It reached the driver whole, became one router whose rule was
  # ``Host(`communication.ventures,matrix.communication.ventures`)``, and cost an ACME
  # order rejected for an identifier that cannot exist -- while the app simply never came
  # up on either name. Traefik reports that once, at startup, as a rule it declined to
  # build; nothing surfaces it to the operator who typed it.
  #
  # A multi-host value is called out BY NAME rather than folded into a generic format
  # error, because the operator's intent was correct and only the field was wrong: they
  # have two hostnames and want both routed. The message names the field that takes the
  # rest, so the fix is a step rather than a guess. The forms split such a value before
  # it ever gets here (see `Hostname.split_primary/1`); this is the backstop for the API
  # and for anything that writes a changeset directly.
  #
  # Scoped to `get_change/2`, NOT `get_field/2`. A validation that reads the persisted
  # value runs on every update, including the overwhelming majority that never mention
  # the field -- so a row stored before this validation existed (a single-label
  # `nextcloud`, an underscore host, an IDN) would become permanently un-updatable, and
  # the paths that would break are the hot ones: `update_deployment/2` setting
  # `status: :pending` on redeploy, the container and reclaim steps, storage. A legacy
  # value stays readable and deployable until someone edits the field; validating what
  # is being WRITTEN is the whole job, and it is how `normalize_domain/1` above already
  # scopes itself.
  #
  # `nil` covers both "not changed" and "explicitly cleared", and neither needs checking:
  # a deployment without a domain is simply not routed.
  defp validate_domain(changeset) do
    case get_change(changeset, :domain) do
      nil ->
        changeset

      domain when is_binary(domain) ->
        cond do
          Hostname.valid?(domain) ->
            changeset

          Hostname.multi_host?(domain) ->
            add_error(
              changeset,
              :domain,
              "must be a single hostname -- list the rest under additional domains"
            )

          true ->
            add_error(changeset, :domain, "is not a valid hostname")
        end

      _ ->
        add_error(changeset, :domain, "is not a valid hostname")
    end
  end

  # Aliases are canonicalized on write for the same reason the primary domain is: the
  # stored string is what becomes a router name (`sanitize_domain/1`) and an ACME
  # identifier, and two spellings of one host would otherwise be two routers racing for
  # one certificate. Runs BEFORE validation so the check below sees what will be stored.
  #
  # A host that normalizes to nothing is left as-is rather than nulled -- validation is
  # about to reject it, and it should name what the operator typed.
  defp normalize_additional_domains(changeset) do
    case get_change(changeset, :additional_domains) do
      domains when is_list(domains) ->
        put_change(changeset, :additional_domains, Enum.map(domains, &normalize_domain_entry/1))

      _ ->
        changeset
    end
  end

  defp normalize_domain_entry(%{"host" => host} = entry) when is_binary(host) do
    case Hostname.normalize(host) do
      nil -> entry
      normalized -> Map.put(entry, "host", normalized)
    end
  end

  defp normalize_domain_entry(entry), do: entry

  # An additional domain becomes its own Traefik router. A malformed one fails the same
  # silent way an extra route does -- Traefik declines it and the second hostname 404s
  # with nothing in the logs -- so reject it here, at the form. Only `host` is required;
  # `path_prefix` (scope the host to a path) and `port` (a distinct backend) are optional.
  defp validate_additional_domains(changeset) do
    case get_change(changeset, :additional_domains) do
      nil ->
        changeset

      domains when is_list(domains) ->
        primary = Hostname.normalize(get_field(changeset, :domain))

        Enum.reduce(domains, changeset, fn entry, acc ->
          cond do
            not valid_host?(entry["host"]) ->
              add_error(
                acc,
                :additional_domains,
                "host is required and must be a domain (got #{inspect(entry["host"])})"
              )

            not optional_path_prefix?(entry["path_prefix"]) ->
              add_error(
                acc,
                :additional_domains,
                "path must start with / (got #{inspect(entry["path_prefix"])})"
              )

            not optional_port?(entry["port"]) ->
              add_error(
                acc,
                :additional_domains,
                "port must be 1-65535 (got #{inspect(entry["port"])})"
              )

            duplicates_primary?(entry, primary) ->
              add_error(
                acc,
                :additional_domains,
                "#{entry["host"]} is already this deployment's domain"
              )

            true ->
              acc
          end
        end)

      _ ->
        add_error(changeset, :additional_domains, "must be a list")
    end
  end

  # Through the same module the primary domain goes through, so "what is a hostname" has
  # exactly one answer. The hand-rolled check this replaced excluded spaces and slashes
  # but not COMMAS -- which is to say an alias row could carry the very multi-host value
  # the primary field is now guarded against, and land the same unbuildable rule one
  # router over.
  defp valid_host?(host), do: Hostname.valid?(host)

  # A bare alias naming the deployment's own domain is not a second host -- it is the
  # SAME router. `additional_router_name/2` derives a router name from the host, so an
  # unscoped duplicate produces the base router's own name and its labels overwrite the
  # base's in the merged map. That is silent and it is not harmless: an alias carrying a
  # `port` rewrites `traefik.http.services.<base>.loadbalancer.server.port`, so the
  # PRIMARY route quietly starts serving a different backend than `routed_port` says.
  #
  # A path-scoped duplicate is fine and stays allowed: it gets a name including the path,
  # so it is a genuinely distinct router (the same shape an extra path route takes).
  defp duplicates_primary?(entry, primary) when is_binary(primary) do
    blank?(entry["path_prefix"]) and Hostname.normalize(entry["host"]) == primary
  end

  defp duplicates_primary?(_entry, _primary), do: false

  defp blank?(value), do: value in [nil, ""]

  # path_prefix and port are optional on an additional domain -- absent means "the whole
  # host to the routed port". A PRESENT value still has to be well-formed.
  defp optional_path_prefix?(path) when path in [nil, ""], do: true
  defp optional_path_prefix?(path), do: valid_path_prefix?(path)

  defp optional_port?(port) when port in [nil, ""], do: true
  defp optional_port?(port), do: valid_port?(port)

  @doc "All valid exposure-mode override values (strings)."
  def exposure_modes, do: @exposure_modes

  def status_changeset(deployment, status, opts \\ []) do
    attrs = %{status: status}

    attrs =
      if error = Keyword.get(opts, :error), do: Map.put(attrs, :error_message, error), else: attrs

    attrs =
      if ext_id = Keyword.get(opts, :external_id),
        do: Map.put(attrs, :external_id, ext_id),
        else: attrs

    deployment
    |> cast(attrs, [:status, :error_message, :external_id])
    |> validate_inclusion(:status, @statuses)
  end

  def reconciled_changeset(deployment) do
    deployment
    |> cast(%{last_reconciled_at: DateTime.utc_now()}, [:last_reconciled_at])
  end
end
