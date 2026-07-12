defmodule Homelab.Catalog.Enrichers.MigrationDetector do
  @moduledoc """
  Detects whether an image ships an app framework that owns database migrations,
  and what command runs them.

  Why this exists: aut.hair came up healthy, served a Laravel 500, and the cause
  (`php artisan migrate` had never run) was only findable by shelling into the
  container. A deployment that needs migrations should say so BEFORE it takes
  traffic, not after.

  ## How it probes

  `ImageInspector` reads the image *config blob* from the registry — ports, env,
  labels — so it cannot see the filesystem, and an `artisan` file is a filesystem
  fact. So we ask the daemon instead: create a container from the image, `GET
  /containers/{id}/archive?path=…` to stat each candidate path (200 = present,
  404 = absent), then remove it.

  The container is **created and never started**. Statting a path must not run the
  image's entrypoint: detection happens on images we have not yet chosen to trust,
  and executing one to look at it would be the wrong trade.

  Detection is a *suggestion*. It fills in a default the operator can override — it
  never silently runs anything.
  """

  require Logger

  alias Homelab.Docker.Client

  @type detection :: %{
          framework: atom(),
          path: String.t(),
          working_dir: String.t(),
          migrate_command: String.t()
        }

  # Ordered: the first signature whose path exists wins. Paths are the conventional
  # app roots each framework's images use.
  @signatures [
    %{
      framework: :laravel,
      paths: ["/var/www/html/artisan", "/app/artisan", "/var/www/artisan", "/srv/app/artisan"],
      # --force: artisan refuses to migrate in production without it, and a release
      # step has no TTY to confirm at.
      migrate_command: "php artisan migrate --force"
    },
    %{
      framework: :rails,
      paths: ["/app/bin/rails", "/rails/bin/rails", "/usr/src/app/bin/rails"],
      migrate_command: "bin/rails db:migrate"
    },
    %{
      framework: :django,
      paths: ["/app/manage.py", "/usr/src/app/manage.py", "/code/manage.py"],
      migrate_command: "python manage.py migrate --noinput"
    },
    %{
      framework: :alembic,
      paths: ["/app/alembic.ini", "/usr/src/app/alembic.ini"],
      migrate_command: "alembic upgrade head"
    }
  ]

  @doc """
  Returns `{:ok, detection}` when the image ships a known migration framework,
  `{:ok, nil}` when it does not, or `{:error, reason}` if the image could not be
  probed at all (e.g. not present on the daemon).

  "No framework found" is an honest success — most images genuinely have none.
  """
  @spec detect(String.t()) :: {:ok, detection() | nil} | {:error, term()}
  def detect(image) when is_binary(image) do
    with {:ok, container_id} <- create_probe_container(image) do
      try do
        {:ok, probe(container_id)}
      after
        remove_probe_container(container_id)
      end
    end
  end

  @doc "The candidate signatures, exposed for the catalog UI and tests."
  def signatures, do: @signatures

  defp probe(container_id) do
    Enum.find_value(@signatures, fn signature ->
      case Enum.find(signature.paths, &file_exists?(container_id, &1)) do
        nil ->
          nil

        path ->
          %{
            framework: signature.framework,
            path: path,
            working_dir: Path.dirname(path),
            migrate_command: signature.migrate_command
          }
      end
    end)
  end

  # A stat, not a read: the daemon answers 200 with a tar of the entry, or 404.
  defp file_exists?(container_id, path) do
    case Client.get("/containers/#{container_id}/archive?path=#{URI.encode_www_form(path)}") do
      {:ok, _tar} -> true
      {:error, {:not_found, _}} -> false
      {:error, reason} -> throw({:probe_failed, path, reason})
    end
  end

  defp create_probe_container(image) do
    # No Cmd/Entrypoint override is needed because the container is never started.
    case Client.post("/containers/create", %{"Image" => image}) do
      {:ok, %{"Id" => id}} ->
        {:ok, id}

      {:error, {:not_found, _}} ->
        {:error, {:image_not_present, image}}

      {:error, reason} ->
        {:error, {:probe_container_failed, image, reason}}
    end
  end

  # Best-effort: a leaked probe container is noise, not a failure of detection.
  defp remove_probe_container(id) do
    case Client.delete("/containers/#{id}?force=true") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[MigrationDetector] could not remove probe container #{id}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
