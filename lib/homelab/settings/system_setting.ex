defmodule Homelab.Settings.SystemSetting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "system_settings" do
    field :key, :string
    field :value, :string
    field :encrypted, :boolean, default: false
    field :category, :string, default: "general"

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value, :encrypted, :category])
    |> validate_required([:key, :category])
    |> unique_constraint(:key)
  end
end
