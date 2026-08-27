defmodule Homelab.Catalog.AppTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  schema "app_templates" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :version, :string
    field :image, :string

    # Access model: :public / :sso_protected / :private are reverse-proxy modes
    # (auth = none / SSO / IP-allowlist), :host binds host ports, :host_network puts
    # the container in the host's network namespace, :service is internal-only. Proxy
    # modes never bind host ports; :host and :host_network never get a route.
    field :exposure_mode, Ecto.Enum,
      values: [:private, :sso_protected, :public, :service, :host, :host_network],
      default: :sso_protected

    field :auth_integration, :boolean, default: true
    field :default_env, :map, default: %{}
    field :required_env, {:array, :string}, default: []
    field :volumes, {:array, :map}, default: []
    # Names this service must keep answering to on its network. An adopted container is
    # renamed by the plane, so without these every sibling that reached it by its compose
    # service name (`DB_HOST=mysql`) silently loses it.
    field :network_aliases, {:array, :string}, default: []

    # What the container RUNS. nil = the image default. A compose file routinely overrides
    # this, and an adopted service running the image default is not the service that was
    # adopted -- silently, if the default happens to stay up.
    field :command, {:array, :string}
    field :entrypoint, {:array, :string}

    # What the container may ask the KERNEL for. A VPN client needs NET_ADMIN and
    # /dev/net/tun, a Zigbee coordinator needs its USB dongle, WireGuard needs
    # net.ipv4.conf.all.src_valid_mark. Without these an app of that shape can be
    # described here but never actually work. See Deployments.RuntimeSpec.
    field :capabilities_add, {:array, :string}
    field :capabilities_drop, {:array, :string}
    field :devices, {:array, :map}
    field :sysctls, :map

    # What kind of network DONOR this image is, when it is one (nil = not a donor).
    # Sharing a namespace is generic; making the shared namespace usable is not —
    # gluetun's firewall drops a child's traffic unless its ports and the Docker subnets
    # are named in its env. See SpecBuilder's donor-env derivation.
    field :netns_donor_kind, :string

    field :ports, {:array, :map}, default: []
    field :resource_limits, :map, default: %{}
    field :backup_policy, :map, default: %{}
    field :health_check, :map, default: %{}
    field :depends_on, {:array, :string}, default: []
    field :source, :string, default: "seeded"
    field :source_id, :string
    field :logo_url, :string
    field :category, :string

    # Container user (uid:gid) for adopted services — preserves the original
    # ownership so we never chown adopted data. nil = image default.
    field :user, :string

    field :auth_mode, Ecto.Enum,
      values: [:oidc_standard, :device_flow, :app_token, :none],
      default: :none

    has_many :deployments, Homelab.Deployments.Deployment

    timestamps()
  end

  @required_fields ~w(slug name version image)a
  @optional_fields ~w(description exposure_mode auth_integration default_env required_env
                      volumes network_aliases command entrypoint
                      capabilities_add capabilities_drop devices sysctls netns_donor_kind
                      ports resource_limits backup_policy health_check depends_on
                      source source_id logo_url category auth_mode user)a

  def changeset(app_template, attrs) do
    app_template
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_length(:slug, min: 2, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    # A template's volumes are inherited by every deployment of it, so a folder mount
    # that loses its host `source` here mounts an empty volume for all of them at once.
    |> Homelab.Deployments.VolumeSpec.validate_changeset(:volumes)
    |> Homelab.Deployments.GpuSpec.validate_changeset(:resource_limits)
    # A template's privileges are inherited by every deployment of it, so a typo'd
    # capability or a device path that does not exist is wrong everywhere at once —
    # and each of the three fails quietly rather than loudly. See RuntimeSpec.
    |> Homelab.Deployments.RuntimeSpec.validate_capabilities(:capabilities_add)
    |> Homelab.Deployments.RuntimeSpec.validate_capabilities(:capabilities_drop, allow_all: true)
    |> Homelab.Deployments.RuntimeSpec.validate_devices(:devices)
    |> Homelab.Deployments.RuntimeSpec.validate_sysctls(:sysctls)
    |> unique_constraint(:slug)
  end
end
