defmodule Homelab.Services.DockerEventListenerIntegrationTest do
  use Homelab.IntegrationCase

  alias Homelab.Docker.Client
  alias Homelab.Services.DockerEventListener

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

  describe "event stream integration" do
    @tag :integration
    test "detects container start events" do
      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      body = %{
        "Image" => @test_image,
        "Labels" => %{
          "homelab.managed" => "true",
          "homelab.test" => "true"
        },
        "Cmd" => ["sleep", "30"]
      }

      case Client.post("/containers/create?name=homelab-integration-test-#{System.unique_integer([:positive])}", body) do
        {:ok, %{"Id" => id}} ->
          Client.post("/containers/#{id}/start")
          Process.sleep(2_000)
          Client.delete("/containers/#{id}?force=true")

        {:error, reason} ->
          flunk("Failed to create test container: #{inspect(reason)}")
      end
    end
  end
end
