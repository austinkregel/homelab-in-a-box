defmodule HomelabWeb.Api.V1.FallbackController do
  use HomelabWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: HomelabWeb.Api.V1.ErrorJSON)
    |> render(:error, status: 404, message: "Resource not found")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: HomelabWeb.Api.V1.ErrorJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, {:missing_required_env, keys}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: HomelabWeb.Api.V1.ErrorJSON)
    |> render(:error,
      status: 422,
      message: "Missing required environment variables: #{Enum.join(keys, ", ")}"
    )
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:internal_server_error)
    |> put_view(json: HomelabWeb.Api.V1.ErrorJSON)
    |> render(:error, status: 500, message: inspect(reason))
  end
end
