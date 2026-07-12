defmodule Homelab.Catalog.Enrichers.MigrationDetectorTest do
  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Catalog.Enrichers.MigrationDetector

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  # GET /containers/{id}/archive?path=X -- 200 when the path exists, 404 when it does not.
  defp stub_probe(present) do
    Homelab.Mocks.DockerClient
    |> stub(:post, fn "/containers/create", %{"Image" => _}, _opts ->
      {:ok, %{"Id" => "probe123"}}
    end)
    |> stub(:delete, fn "/containers/probe123?force=true", _opts -> {:ok, %{}} end)
    |> stub(:get, fn path, _opts ->
      probed = path |> URI.parse() |> Map.get(:query) |> URI.decode_query() |> Map.get("path")

      if probed in present do
        {:ok, "<tar bytes>"}
      else
        {:error, {:not_found, %{"message" => "not found"}}}
      end
    end)
  end

  test "detects Laravel from /var/www/html/artisan" do
    stub_probe(["/var/www/html/artisan"])

    assert {:ok, detection} = MigrationDetector.detect("ghcr.io/austinkregel/aut.hair:latest")
    assert detection.framework == :laravel
    assert detection.path == "/var/www/html/artisan"
    assert detection.working_dir == "/var/www/html"
    assert detection.migrate_command == "php artisan migrate --force"
  end

  test "detects Laravel from /app/artisan" do
    stub_probe(["/app/artisan"])

    assert {:ok, %{framework: :laravel, working_dir: "/app"}} = MigrationDetector.detect("some/img")
  end

  test "detects Rails and Django" do
    stub_probe(["/rails/bin/rails"])
    assert {:ok, %{framework: :rails}} = MigrationDetector.detect("some/img")

    stub_probe(["/app/manage.py"])
    assert {:ok, %{framework: :django}} = MigrationDetector.detect("some/img")
  end

  # Most images genuinely ship no migration framework. That is a success, not an error.
  test "an image with no framework is an honest nil" do
    stub_probe([])

    assert {:ok, nil} = MigrationDetector.detect("redis:7-alpine")
  end

  test "the probe container is always removed, even when nothing is found" do
    test_pid = self()

    Homelab.Mocks.DockerClient
    |> stub(:post, fn "/containers/create", _body, _opts -> {:ok, %{"Id" => "probe123"}} end)
    |> stub(:get, fn _path, _opts -> {:error, {:not_found, %{}}} end)
    |> expect(:delete, fn "/containers/probe123?force=true", _opts ->
      send(test_pid, :removed)
      {:ok, %{}}
    end)

    assert {:ok, nil} = MigrationDetector.detect("redis:7-alpine")
    assert_received :removed
  end

  # The container is CREATED but never STARTED -- statting a path must not execute an
  # image we have not yet decided to trust.
  test "never starts the probe container" do
    Homelab.Mocks.DockerClient
    |> stub(:post, fn path, _body, _opts ->
      refute String.contains?(path, "/start"), "the probe must never start the container"
      {:ok, %{"Id" => "probe123"}}
    end)
    |> stub(:get, fn _path, _opts -> {:error, {:not_found, %{}}} end)
    |> stub(:delete, fn _path, _opts -> {:ok, %{}} end)

    assert {:ok, nil} = MigrationDetector.detect("redis:7-alpine")
  end

  test "an image the daemon does not have is a clear error, not a false negative" do
    Homelab.Mocks.DockerClient
    |> stub(:post, fn "/containers/create", _body, _opts -> {:error, {:not_found, %{}}} end)

    assert {:error, {:image_not_present, "ghost:1"}} = MigrationDetector.detect("ghost:1")
  end
end
