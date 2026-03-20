defmodule Homelab.Docker.ClientTest do
  use ExUnit.Case, async: true

  alias Homelab.Docker.Client

  describe "socket_path/0" do
    test "returns default socket path" do
      assert Client.socket_path() == "/var/run/docker.sock"
    end
  end

  describe "build_url (via requests)" do
    @tag :integration
    test "GET /info connects to Docker daemon" do
      case Client.get("/info") do
        {:ok, info} ->
          assert is_map(info)
          assert Map.has_key?(info, "ID")

        {:error, {:connection_error, _}} ->
          # Docker not available, skip gracefully
          :ok
      end
    end
  end
end
