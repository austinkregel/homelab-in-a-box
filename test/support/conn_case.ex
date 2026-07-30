defmodule HomelabWeb.ConnCase do
  use ExUnit.CaseTemplate

  import Plug.Conn

  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.
  """

  using do
    quote do
      @endpoint HomelabWeb.Endpoint

      use HomelabWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import HomelabWeb.ConnCase
    end
  end

  setup tags do
    Homelab.DataCase.setup_sandbox(tags)
    Homelab.Settings.init_cache()
    Homelab.Settings.mark_setup_completed()

    user = Homelab.Factory.insert(:user)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_session(:user_id, user.id)

    {:ok, conn: conn, user: user}
  end

  @doc """
  Logs in the given user by putting user_id in the session.
  """
  def log_in_user(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> put_session(:user_id, user.id)
  end

  @doc """
  A conn with NO session — nobody is logged in.

  The `conn` this case template hands every test is already authenticated, which is
  convenient and was also how a completely unauthenticated `/api/v1` surface passed nine
  test files: every one of them was logged in by accident, so none could observe that
  the routes were not protected. Reach for this whenever the thing under test is
  *whether* something is protected.
  """
  def unauthenticated_conn do
    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
  end
end
