defmodule Homelab.Deployments.DeploymentSecret do
  @moduledoc """
  A per-deployment secret (DB user/password/name, …) generated once and reused.

  `value` is stored encrypted at rest (`Homelab.Crypto`). The
  `[:deployment_id, :key]` unique constraint is the generate-once guard: the
  provisioning step does a get-or-create so a retried release reuses the same
  credentials rather than regenerating them.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "deployment_secrets" do
    field :key, :string
    field :value, :string

    belongs_to :deployment, Homelab.Deployments.Deployment

    timestamps()
  end

  @required_fields ~w(deployment_id key value)a

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:deployment_id)
    |> unique_constraint([:deployment_id, :key])
  end
end
