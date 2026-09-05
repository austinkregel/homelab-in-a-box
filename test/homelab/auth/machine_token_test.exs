defmodule Homelab.Auth.MachineTokenTest do
  # Not async: the settings and discovery caches are global ETS tables.
  use Homelab.DataCase, async: false

  alias Homelab.Accounts
  alias Homelab.Auth.MachineToken

  setup do
    bypass = Bypass.open()
    Homelab.Settings.set("oidc_issuer", "http://localhost:#{bypass.port}")
    MachineToken.reset_cache()

    on_exit(fn ->
      Homelab.Settings.delete("oidc_issuer")
      Homelab.Settings.delete("oidc_machine_scope")
      MachineToken.reset_cache()
    end)

    {:ok, bypass: bypass}
  end

  defp stub_discovery(bypass, overrides \\ %{}) do
    body =
      Map.merge(
        %{
          "issuer" => "http://localhost:#{bypass.port}",
          "token_endpoint" => "http://localhost:#{bypass.port}/oauth/token",
          "userinfo_endpoint" => "http://localhost:#{bypass.port}/api/userinfo",
          "machine_info_endpoint" => "http://localhost:#{bypass.port}/api/machine-info",
          "grant_types_supported" => ["authorization_code", "refresh_token", "client_credentials"]
        },
        overrides
      )

    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_machine_info(bypass, status, body) do
    Bypass.stub(bypass, "GET", "/api/machine-info", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  describe "authenticate/1 on the happy path" do
    setup %{bypass: bypass} do
      stub_discovery(bypass)

      stub_machine_info(bypass, 200, %{
        "client_id" => "mcp-1",
        "name" => "MCP Server",
        "scopes" => ["openid", "homelab"]
      })

      :ok
    end

    test "resolves the token to a :service principal" do
      assert {:ok, user, scopes} = MachineToken.authenticate("tok-abc")

      assert user.role == :service
      assert user.sub == "service:mcp-1"
      assert user.name == "MCP Server"
      assert scopes == ["openid", "homelab"]
    end

    test "the principal is never an administrator" do
      assert {:ok, user, _} = MachineToken.authenticate("tok-abc")
      refute Accounts.admin?(user)
      assert Accounts.service?(user)
    end

    test "reuses the row across calls and records last use" do
      assert {:ok, first, _} = MachineToken.authenticate("tok-abc")
      assert {:ok, second, _} = MachineToken.authenticate("tok-abc")

      assert first.id == second.id
      assert second.last_login_at
    end

    test "logs the first sighting of a machine, and only the first" do
      assert {:ok, user, _} = MachineToken.authenticate("tok-abc")
      assert {:ok, _, _} = MachineToken.authenticate("tok-abc")
      assert {:ok, _, _} = MachineToken.authenticate("tok-abc")

      entries = Homelab.Audit.list_for_resource("user", user.id)
      assert [%{action: "service_account.first_seen"}] = entries
    end
  end

  describe "authenticate/1 refusals" do
    test "refuses when the issuer rejects the token", %{bypass: bypass} do
      stub_discovery(bypass)
      stub_machine_info(bypass, 401, %{"error" => "invalid_token"})

      assert {:error, :invalid_token} = MachineToken.authenticate("nope")
      assert Accounts.list_users() == []
    end

    test "refuses when the issuer says the scope is insufficient", %{bypass: bypass} do
      stub_discovery(bypass)
      stub_machine_info(bypass, 403, %{"error" => "insufficient_scope"})

      assert {:error, :insufficient_scope} = MachineToken.authenticate("tok")
    end

    test "refuses a validly-issued token that lacks the required scope", %{bypass: bypass} do
      stub_discovery(bypass)

      stub_machine_info(bypass, 200, %{
        "client_id" => "other-app",
        "name" => "Some Other Client",
        "scopes" => ["openid", "email"]
      })

      # Real token, wrong audience — no row is created for a client that cannot get in.
      assert {:error, :insufficient_scope} = MachineToken.authenticate("tok")
      assert Accounts.list_users() == []
    end

    test "honours a custom required scope", %{bypass: bypass} do
      Homelab.Settings.set("oidc_machine_scope", "lab:agent")
      stub_discovery(bypass)

      stub_machine_info(bypass, 200, %{
        "client_id" => "mcp-1",
        "scopes" => ["openid", "lab:agent"]
      })

      assert {:ok, user, _} = MachineToken.authenticate("tok")
      assert user.sub == "service:mcp-1"
    end

    test "accepts a space-delimited scope string", %{bypass: bypass} do
      stub_discovery(bypass)
      stub_machine_info(bypass, 200, %{"client_id" => "mcp-1", "scope" => "openid homelab"})

      assert {:ok, _, scopes} = MachineToken.authenticate("tok")
      assert scopes == ["openid", "homelab"]
    end

    test "refuses when the issuer cannot identify machines", %{bypass: bypass} do
      stub_discovery(bypass, %{
        "machine_info_endpoint" => nil,
        "grant_types_supported" => ["authorization_code"]
      })

      assert {:error, :no_machine_info_endpoint} = MachineToken.authenticate("tok")
    end

    test "refuses when no issuer is configured", %{bypass: bypass} do
      Bypass.down(bypass)
      Homelab.Settings.delete("oidc_issuer")
      MachineToken.reset_cache()

      assert {:error, :not_configured} = MachineToken.authenticate("tok")
    end

    test "refuses when the issuer is unreachable", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:connection_error, _}} = MachineToken.authenticate("tok")
    end

    test "refuses a non-binary token", %{bypass: bypass} do
      stub_discovery(bypass)
      assert {:error, :invalid_token} = MachineToken.authenticate(nil)
    end
  end

  describe "discovery caching" do
    test "fetches discovery once across many authentications", %{bypass: bypass} do
      counter = :counters.new(1, [])

      Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        :counters.add(counter, 1, 1)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "issuer" => "http://localhost:#{bypass.port}",
            "machine_info_endpoint" => "http://localhost:#{bypass.port}/api/machine-info",
            "grant_types_supported" => ["client_credentials"]
          })
        )
      end)

      stub_machine_info(bypass, 200, %{"client_id" => "mcp-1", "scopes" => ["homelab"]})

      assert {:ok, _, _} = MachineToken.authenticate("tok")
      assert {:ok, _, _} = MachineToken.authenticate("tok")
      assert {:ok, _, _} = MachineToken.authenticate("tok")

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "required_scope/0" do
    test "defaults to homelab and trims a configured value" do
      assert MachineToken.required_scope() == "homelab"

      Homelab.Settings.set("oidc_machine_scope", "  lab:agent  ")
      assert MachineToken.required_scope() == "lab:agent"

      Homelab.Settings.set("oidc_machine_scope", "   ")
      assert MachineToken.required_scope() == "homelab"
    end
  end
end
