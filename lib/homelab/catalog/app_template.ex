defmodule Homelab.Catalog.AppTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  schema "app_templates" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :version, :string
    field :image, :string

    field :exposure_mode, Ecto.Enum,
      values: [:private, :sso_protected, :public, :service],
      default: :sso_protected

    field :auth_integration, :boolean, default: true
    field :default_env, :map, default: %{}
    field :required_env, {:array, :string}, default: []
    field :volumes, {:array, :map}, default: []
    field :ports, {:array, :map}, default: []
    field :resource_limits, :map, default: %{}
    field :backup_policy, :map, default: %{}
    field :health_check, :map, default: %{}

    field :consistency_mode, Ecto.Enum,
      values: [:filesystem, :crash_consistent, :app_aware],
      default: :crash_consistent

    field :pre_snapshot_cmd, :map
    field :post_snapshot_cmd, :map
    field :depends_on, {:array, :string}, default: []
    field :source, :string, default: "seeded"
    field :source_id, :string
    field :logo_url, :string
    field :category, :string

    field :auth_mode, Ecto.Enum,
      values: [:oidc_standard, :device_flow, :app_token, :none],
      default: :none

    has_many :deployments, Homelab.Deployments.Deployment

    timestamps()
  end

  @required_fields ~w(slug name version image)a
  @optional_fields ~w(description exposure_mode auth_integration default_env required_env
                      volumes ports resource_limits backup_policy health_check depends_on
                      consistency_mode pre_snapshot_cmd post_snapshot_cmd
                      source source_id logo_url category auth_mode)a

  def changeset(app_template, attrs) do
    app_template
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_health_check()
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/,
      message: "must be lowercase alphanumeric with hyphens"
    )
    |> validate_length(:slug, min: 2, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint(:slug)
  end

  defp validate_health_check(changeset) do
    case get_field(changeset, :health_check) do
      hc when is_map(hc) ->
        case Homelab.Catalog.HealthCheck.validate(hc) do
          :ok -> changeset
          {:error, msgs} -> add_error(changeset, :health_check, Enum.join(msgs, "; "))
        end

      _ ->
        changeset
    end
  end
end
