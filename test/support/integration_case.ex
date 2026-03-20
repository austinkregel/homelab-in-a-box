defmodule Homelab.IntegrationCase do
  @moduledoc """
  Test case for integration tests that require external services.

  These tests are excluded by default and can be run with:

      mix test --include integration

  The integration tests require:
  - A running Docker daemon with Swarm mode enabled
  - Network access to the Docker socket

  ## Usage

      use Homelab.IntegrationCase

  This will:
  - Automatically tag the test module with `@moduletag :integration`
  - Provide helper functions for Docker interaction
  - Clean up any test services after each test
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      import Homelab.IntegrationCase

      alias Homelab.Docker.Client
      alias Homelab.Orchestrators.DockerSwarm
    end
  end

  setup do
    # Track services created during this test for cleanup
    {:ok, created_services: []}
  end

  @doc """
  Checks if Docker is available and Swarm mode is active.
  Returns {:ok, info} or {:error, reason}.
  """
  def docker_available? do
    case Homelab.Docker.Client.get("/info") do
      {:ok, %{"Swarm" => %{"LocalNodeState" => "active"}} = info} ->
        {:ok, info}

      {:ok, %{"Swarm" => %{"LocalNodeState" => state}}} ->
        {:error, {:swarm_not_active, state}}

      {:ok, _info} ->
        {:error, :swarm_status_unknown}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Creates a test network for tenant isolation testing.
  """
  def create_test_network(name) do
    body = %{
      "Name" => name,
      "Driver" => "overlay",
      "Attachable" => true,
      "Labels" => %{"homelab.test" => "true"}
    }

    Homelab.Docker.Client.post("/networks/create", body)
  end

  @doc """
  Removes a test network.
  """
  def remove_test_network(name) do
    Homelab.Docker.Client.delete("/networks/#{name}")
  end

  @doc """
  Waits for a service to reach the desired state, with timeout.
  """
  def wait_for_service(service_id, desired_state, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_service(service_id, desired_state, deadline)
  end

  defp poll_service(service_id, desired_state, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      {:error, :timeout}
    else
      case Homelab.Orchestrators.DockerSwarm.get_service(service_id) do
        {:ok, %{state: ^desired_state} = status} ->
          {:ok, status}

        {:ok, _} ->
          Process.sleep(500)
          poll_service(service_id, desired_state, deadline)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
