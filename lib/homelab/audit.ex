defmodule Homelab.Audit do
  @moduledoc """
  Context for activity/audit logging.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Audit.ActivityLog

  @doc """
  Logs an activity. opts can include:
  - :user_id - the user who performed the action (optional)
  - :metadata - additional map data (optional)
  """
  def log(action, resource_type, resource_id \\ nil, opts \\ []) do
    attrs =
      %{
        action: action,
        resource_type: resource_type,
        resource_id: resource_id,
        metadata: Keyword.get(opts, :metadata, %{}),
        inserted_at: DateTime.utc_now()
      }
      |> maybe_put_user(opts)

    %ActivityLog{}
    |> ActivityLog.changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_put_user(attrs, opts) do
    case Keyword.get(opts, :user_id) do
      nil -> attrs
      user_id -> Map.put(attrs, :user_id, user_id)
    end
  end

  @doc """
  Returns recent activity logs, ordered by inserted_at desc.
  Preloads user. Default limit is 50.
  """
  def list_recent(limit \\ 50) do
    ActivityLog
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Returns activity logs for a specific resource.
  """
  def list_for_resource(resource_type, resource_id) do
    ActivityLog
    |> where(resource_type: ^resource_type, resource_id: ^resource_id)
    |> order_by([a], desc: a.inserted_at)
    |> preload(:user)
    |> Repo.all()
  end
end
