defmodule HomelabWeb.Api.V1.SpaceJSON do
  alias Homelab.Tenants.Tenant

  def index(%{spaces: spaces}) do
    %{data: Enum.map(spaces, &data/1)}
  end

  def show(%{space: space}) do
    %{data: data(space)}
  end

  defp data(%Tenant{} = space) do
    %{
      id: space.id,
      name: space.name,
      slug: space.slug,
      status: space.status,
      settings: space.settings,
      inserted_at: space.inserted_at,
      updated_at: space.updated_at
    }
  end
end
