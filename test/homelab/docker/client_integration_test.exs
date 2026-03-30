defmodule Homelab.Docker.ClientIntegrationTest do
  use Homelab.IntegrationCase

  alias Homelab.Docker.Client

  @test_image "homelab-test:latest"

  setup do
    case Client.get("/info") do
      {:ok, _} -> :ok
      {:error, _} -> {:skip, "Docker daemon not available"}
    end

    on_exit(fn ->
      case Client.get("/containers/json?all=true&filters=#{URI.encode_www_form(Jason.encode!(%{"label" => ["homelab.test=true"]}))}" ) do
        {:ok, containers} when is_list(containers) ->
          Enum.each(containers, fn c ->
            Client.delete("/containers/#{c["Id"]}?force=true")
          end)

        _ ->
          :ok
      end
    end)

    :ok
  end

  describe "container lifecycle" do
    @tag :integration
    test "create, inspect, and remove a container" do
      name = "homelab-client-test-#{System.unique_integer([:positive])}"

      body = %{
        "Image" => @test_image,
        "Labels" => %{
          "homelab.managed" => "true",
          "homelab.test" => "true"
        },
        "Cmd" => ["sleep", "10"]
      }

      assert {:ok, %{"Id" => id}} = Client.post("/containers/create?name=#{name}", body)
      assert {:ok, %{"Id" => ^id}} = Client.get("/containers/#{name}/json")
      assert {:ok, _} = Client.post("/containers/#{name}/start")

      Process.sleep(500)

      assert {:ok, container} = Client.get("/containers/#{name}/json")
      assert container["State"]["Running"] == true

      assert {:ok, _} = Client.delete("/containers/#{name}?force=true")
    end
  end

  describe "Docker info" do
    @tag :integration
    test "gets Docker daemon info" do
      assert {:ok, info} = Client.get("/info")
      assert is_map(info)
      assert Map.has_key?(info, "Containers")
    end
  end
end
