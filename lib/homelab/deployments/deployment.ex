defmodule Homelab.Deployments.Deployment do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :deploying, :running, :failed, :stopped, :removing]
  # Same set as AppTemplate.exposure_mode; stored as a string override here so a
  # single deployment can diverge from the (shared) template default.
  @exposure_modes ~w(private sso_protected public service host)

  schema "deployments" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :external_id, :string
    field :domain, :string
    field :env_overrides, :map, default: %{}
    # Per-deployment overrides (nil = inherit the app_template default).
    field :ports_override, {:array, :map}
    field :volumes_override, {:array, :map}
    field :exposure_mode_override, :string
    field :resource_limits_override, :map
    field :health_check_override, :map
    # Reverse-proxy options (sticky sessions, &c).
    field :proxy_options, :map, default: %{}
    # The container port the proxy forwards to. An explicit DECISION, never
    # inferred -- see SpecBuilder.routed_port/1. nil = fall back to the heuristic.
    field :routed_port, :integer
    # Additional path -> port routes, for an app serving a second protocol from a
    # second port (aut.hair: Laravel on 8000, Reverb websockets on 6001 at /app).
    # Each: %{"path_prefix" => "/app", "port" => 6001}.
    field :extra_routes, {:array, :map}, default: []
    field :computed_spec, :map
    field :last_reconciled_at, :utc_datetime
    field :error_message, :string

    belongs_to :tenant, Homelab.Tenants.Tenant
    belongs_to :app_template, Homelab.Catalog.AppTemplate

    has_many :domains, Homelab.Networking.Domain
    has_many :dns_records, Homelab.Networking.DnsRecord
    has_many :backup_jobs, Homelab.Backups.BackupJob

    timestamps()
  end

  @required_fields ~w(tenant_id app_template_id)a
  @optional_fields ~w(status external_id domain env_overrides ports_override
                      volumes_override exposure_mode_override resource_limits_override
                      health_check_override proxy_options routed_port extra_routes
                      computed_spec last_reconciled_at error_message)a

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:exposure_mode_override, @exposure_modes)
    |> validate_number(:routed_port, greater_than: 0, less_than: 65_536)
    |> validate_extra_routes()
    |> validate_volumes_override()
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:app_template_id)
    |> unique_constraint([:tenant_id, :app_template_id])
  end

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

  # A volume is either a managed NAMED volume (Docker keeps the data, name derived from
  # container_path) or a BIND of a host folder (the operator keeps the data where it
  # already is). Both are legitimate; the existing homelab stack is entirely folder
  # mounts, and adopting or matching it is impossible without binds.
  #
  # container_path must be absolute either way: a named volume's NAME is derived from it
  # (SpecBuilder.volume_name/3), so a relative one produces a garbage name and silently
  # mounts the wrong thing.
  #
  # A bind additionally needs an absolute host `source`. Docker would happily interpret a
  # bare word as a NAMED VOLUME rather than a path -- so a typo'd bind source does not
  # error, it quietly creates an empty volume and the app comes up with no data. That
  # failure is indistinguishable from data loss at a glance, so it is refused here.
  #
  # Two volumes at the same container_path is rejected: Docker takes one and drops the
  # other, and which one it takes is not something to leave to chance when the answer
  # decides where an app's data lives.
  defp validate_volumes_override(changeset) do
    case get_change(changeset, :volumes_override) do
      nil ->
        changeset

      volumes when is_list(volumes) ->
        paths = Enum.map(volumes, & &1["container_path"])

        changeset
        |> then(fn cs -> Enum.reduce(volumes, cs, &validate_volume/2) end)
        |> then(fn cs ->
          if length(Enum.uniq(paths)) == length(paths),
            do: cs,
            else: add_error(cs, :volumes_override, "two volumes cannot mount at the same path")
        end)

      _ ->
        add_error(changeset, :volumes_override, "must be a list")
    end
  end

  defp validate_volume(vol, changeset) do
    cond do
      not valid_container_path?(vol["container_path"]) ->
        add_error(
          changeset,
          :volumes_override,
          "mount path must be absolute (got #{inspect(vol["container_path"])})"
        )

      vol["type"] == "bind" and not valid_container_path?(vol["source"]) ->
        add_error(
          changeset,
          :volumes_override,
          "a folder mount needs an absolute host path (got #{inspect(vol["source"])}) — " <>
            "Docker reads a bare name as a named volume, so a typo would silently mount an empty one"
        )

      true ->
        changeset
    end
  end

  defp valid_container_path?(path) when is_binary(path),
    do: String.starts_with?(path, "/") and String.trim(path) != "/"

  defp valid_container_path?(_path), do: false

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
