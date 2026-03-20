defmodule Homelab.IdentityBrokers.GenericOidcTest do
  use ExUnit.Case, async: true

  alias Homelab.IdentityBrokers.GenericOidc

  setup do
    bypass = Bypass.open()

    Application.put_env(:homelab, Homelab.IdentityBrokers.GenericOidc,
      base_url: "http://localhost:#{bypass.port}",
      api_token: "test-token",
      admin_group: "homelab-admins"
    )

    on_exit(fn ->
      Application.delete_env(:homelab, Homelab.IdentityBrokers.GenericOidc)
    end)

    {:ok, bypass: bypass}
  end

  describe "create_client/2" do
    test "creates an OIDC client", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/v3/providers/oauth2/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        parsed = Jason.decode!(body)

        assert parsed["client_id"] == "homelab_my_app"
        assert parsed["authorization_grant_type"] == "authorization-code"
        assert parsed["name"] == "Homelab: My App"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "client_id" => "homelab_my_app",
            "client_secret" => "generated-secret-123",
            "redirect_uris" => "https://myapp.example.com/callback"
          })
        )
      end)

      assert {:ok, client} =
               GenericOidc.create_client("My App", ["https://myapp.example.com/callback"])

      assert client.client_id == "homelab_my_app"
      assert client.client_secret == "generated-secret-123"
      assert client.redirect_uri == "https://myapp.example.com/callback"
    end

    test "handles API errors gracefully", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/v3/providers/oauth2/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"error" => "invalid_request"}))
      end)

      assert {:error, {:http_error, 400, _}} =
               GenericOidc.create_client("Bad App", ["https://bad.example.com"])
    end
  end

  describe "delete_client/1" do
    test "deletes an OIDC client", %{bypass: bypass} do
      Bypass.expect_once(bypass, "DELETE", "/api/v3/providers/oauth2/", fn conn ->
        assert conn.query_string =~ "client_id=homelab_test"

        conn
        |> Plug.Conn.resp(204, "")
      end)

      assert :ok = GenericOidc.delete_client("homelab_test")
    end
  end

  describe "list_clients/0" do
    test "returns list of OIDC clients", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/v3/providers/oauth2/", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "results" => [
              %{
                "client_id" => "homelab_nextcloud",
                "client_secret" => "secret-1",
                "redirect_uris" => "https://nc.example.com/callback"
              },
              %{
                "client_id" => "homelab_gitea",
                "client_secret" => "secret-2",
                "redirect_uris" => "https://git.example.com/callback"
              }
            ]
          })
        )
      end)

      assert {:ok, clients} = GenericOidc.list_clients()
      assert length(clients) == 2
      assert Enum.at(clients, 0).client_id == "homelab_nextcloud"
      assert Enum.at(clients, 1).client_id == "homelab_gitea"
    end
  end

  describe "create_user/2" do
    test "creates a user", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/v3/core/users/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        parsed = Jason.decode!(body)

        assert parsed["email"] == "alice@example.com"
        assert parsed["username"] == "alice"
        assert parsed["is_active"] == true

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          201,
          Jason.encode!(%{
            "pk" => 42,
            "username" => "alice",
            "email" => "alice@example.com"
          })
        )
      end)

      assert {:ok, user} =
               GenericOidc.create_user("alice@example.com", %{name: "Alice"})

      assert user["username"] == "alice"
    end
  end

  describe "assign_user_to_group/2" do
    test "assigns user to group", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/api/v3/core/groups/homelab-users/add_user/", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        parsed = Jason.decode!(body)
        assert parsed["pk"] == "42"

        conn
        |> Plug.Conn.resp(204, "")
      end)

      assert :ok = GenericOidc.assign_user_to_group("42", "homelab-users")
    end
  end

  describe "authentication" do
    test "includes Bearer token in requests", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/v3/providers/oauth2/", fn conn ->
        auth_header =
          conn.req_headers
          |> Enum.find(fn {k, _v} -> k == "authorization" end)
          |> elem(1)

        assert auth_header == "Bearer test-token"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"results" => []}))
      end)

      GenericOidc.list_clients()
    end
  end
end
