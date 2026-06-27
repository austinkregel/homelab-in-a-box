defmodule HomelabWeb.Api.V1.DeploymentJSONTest do
  use ExUnit.Case, async: true

  alias HomelabWeb.Api.V1.DeploymentJSON
  alias Homelab.Deployments.Deployment

  defp deployment(attrs \\ %{}) do
    defaults = %Deployment{
      id: 1,
      status: :running,
      domain: "app.tenant.homelab.local",
      external_id: "ext-123",
      tenant_id: 10,
      app_template_id: 20,
      env_overrides: %{"FOO" => "bar"},
      last_reconciled_at: ~U[2026-06-26 12:00:00Z],
      error_message: nil,
      inserted_at: ~N[2026-06-01 00:00:00],
      updated_at: ~N[2026-06-02 00:00:00]
    }

    struct(defaults, attrs)
  end

  describe "show/1" do
    test "wraps a single deployment under :data" do
      result = DeploymentJSON.show(%{deployment: deployment()})

      assert %{data: data} = result
      assert is_map(data)
    end

    test "renders all expected fields" do
      d = deployment()
      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.id == d.id
      assert data.status == d.status
      assert data.domain == d.domain
      assert data.external_id == d.external_id
      assert data.tenant_id == d.tenant_id
      assert data.app_template_id == d.app_template_id
      assert data.last_reconciled_at == d.last_reconciled_at
      assert data.error_message == d.error_message
      assert data.inserted_at == d.inserted_at
      assert data.updated_at == d.updated_at
    end

    test "exposes exactly the documented key set" do
      %{data: data} = DeploymentJSON.show(%{deployment: deployment()})

      assert Map.keys(data) |> Enum.sort() ==
               Enum.sort([
                 :id,
                 :status,
                 :domain,
                 :external_id,
                 :tenant_id,
                 :app_template_id,
                 :env_overrides,
                 :last_reconciled_at,
                 :error_message,
                 :inserted_at,
                 :updated_at
               ])
    end

    test "passes through non-sensitive env overrides untouched" do
      d = deployment(%{env_overrides: %{"APP_ENV" => "production", "PORT" => "8080"}})
      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.env_overrides == %{"APP_ENV" => "production", "PORT" => "8080"}
    end

    test "renders nil env_overrides as an empty map" do
      d = deployment(%{env_overrides: nil})
      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.env_overrides == %{}
    end

    test "renders empty env_overrides as an empty map" do
      d = deployment(%{env_overrides: %{}})
      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.env_overrides == %{}
    end

    test "preserves nil optional fields" do
      d =
        deployment(%{
          external_id: nil,
          last_reconciled_at: nil,
          error_message: nil
        })

      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.external_id == nil
      assert data.last_reconciled_at == nil
      assert data.error_message == nil
    end

    test "includes error_message when present" do
      d = deployment(%{status: :error, error_message: "container crashed"})
      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.status == :error
      assert data.error_message == "container crashed"
    end
  end

  describe "secret redaction in env_overrides" do
    test "redacts keys containing PASSWORD (case-insensitive)" do
      d =
        deployment(%{
          env_overrides: %{"DB_PASSWORD" => "hunter2", "password" => "p", "MyPasswordX" => "q"}
        })

      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.env_overrides["DB_PASSWORD"] == "***REDACTED***"
      assert data.env_overrides["password"] == "***REDACTED***"
      assert data.env_overrides["MyPasswordX"] == "***REDACTED***"
    end

    test "redacts keys containing SECRET" do
      d = deployment(%{env_overrides: %{"CLIENT_SECRET" => "abc", "secret_key_base" => "x"}})
      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.env_overrides["CLIENT_SECRET"] == "***REDACTED***"
      assert data.env_overrides["secret_key_base"] == "***REDACTED***"
    end

    test "redacts keys containing TOKEN" do
      d = deployment(%{env_overrides: %{"API_TOKEN" => "t", "github_token" => "g"}})
      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.env_overrides["API_TOKEN"] == "***REDACTED***"
      assert data.env_overrides["github_token"] == "***REDACTED***"
    end

    test "redacts KEY but not PUBLIC_KEY" do
      d =
        deployment(%{
          env_overrides: %{
            "PRIVATE_KEY" => "priv",
            "API_KEY" => "k",
            "PUBLIC_KEY" => "pub"
          }
        })

      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.env_overrides["PRIVATE_KEY"] == "***REDACTED***"
      assert data.env_overrides["API_KEY"] == "***REDACTED***"
      assert data.env_overrides["PUBLIC_KEY"] == "pub"
    end

    test "leaves non-sensitive keys untouched alongside sensitive ones" do
      d =
        deployment(%{
          env_overrides: %{"APP_ENV" => "prod", "DB_PASSWORD" => "x", "REGION" => "us"}
        })

      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert data.env_overrides["APP_ENV"] == "prod"
      assert data.env_overrides["REGION"] == "us"
      assert data.env_overrides["DB_PASSWORD"] == "***REDACTED***"
    end

    test "preserves the full set of keys after redaction" do
      env = %{"A" => "1", "TOKEN" => "2", "B" => "3"}
      d = deployment(%{env_overrides: env})
      %{data: data} = DeploymentJSON.show(%{deployment: d})

      assert Map.keys(data.env_overrides) |> Enum.sort() == ["A", "B", "TOKEN"]
    end
  end

  describe "index/1" do
    test "wraps a list of deployments under :data" do
      ds = [deployment(%{id: 1}), deployment(%{id: 2})]
      result = DeploymentJSON.index(%{deployments: ds})

      assert %{data: list} = result
      assert is_list(list)
      assert length(list) == 2
      assert Enum.map(list, & &1.id) == [1, 2]
    end

    test "returns an empty list for no deployments" do
      assert DeploymentJSON.index(%{deployments: []}) == %{data: []}
    end

    test "applies the same data shaping (including redaction) per element" do
      ds = [deployment(%{id: 1, env_overrides: %{"SECRET" => "s", "OK" => "v"}})]
      %{data: [data]} = DeploymentJSON.index(%{deployments: ds})

      assert data.env_overrides["SECRET"] == "***REDACTED***"
      assert data.env_overrides["OK"] == "v"
    end
  end
end
