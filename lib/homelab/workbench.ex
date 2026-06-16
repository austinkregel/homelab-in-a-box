defmodule Homelab.Workbench do
  @moduledoc """
  Workbench projects for custom container builds (§C).
  Build/publish against ZFS datasets is deferred until ZFS is available.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Workbench.{Project, Version}

  def list_projects do
    Project
    |> where([p], is_nil(p.archived_at))
    |> preload(:tenant)
    |> order_by([p], p.name)
    |> Repo.all()
  end

  def get_project!(id), do: Repo.get!(Project, id) |> Repo.preload([:tenant, :versions, :builds])

  def change_project(%Project{} = project \\ %Project{}, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end

  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Next version number for a project."
  def next_version_number(project_id) do
    max =
      Version
      |> where(project_id: ^project_id)
      |> select([v], max(v.version_number))
      |> Repo.one()

    (max || 0) + 1
  end

  @doc "Publish is deferred until ZFS + builder are available."
  def publish_available?, do: Homelab.Storage.available?()
end
