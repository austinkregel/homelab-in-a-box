defmodule Homelab.Deployments.Migrate.ContainerCopyEngine do
  @moduledoc """
  Copy engine that runs the copy + verify inside a throwaway helper container.

  This is the production engine for adopting real data, because it solves three
  problems the in-process `LocalCopyEngine` can't:

    * **Ownership** — it runs `cp -a` as root, preserving uid/gid (a Postgres data
      dir owned by 999:999 stays owned by 999:999). `File.cp_r` can't do that.
    * **Path translation** — the Docker daemon bind-mounts the source and the
      destination into the helper, so it works no matter where the (possibly
      containerized) plane runs, and Docker auto-creates the destination host
      directory — exactly the `device`-bind dir the managed volume needs.
    * **Verification where the bytes are** — it checksums `/src` and `/dest`
      inside the container and compares, so the proof doesn't depend on the plane
      being able to read either path.

  Returns `{:ok, %{"files", "bytes", "digest", "verified" => true}}` on a verified
  match, `{:error, {:verify_mismatch, :container}}` if the copy didn't match, or
  another `{:error, _}` on a daemon/helper failure. The helper container is always
  removed.

  Configure the helper image with `:migrate_helper_image` (default `alpine:3.20`).
  Select this engine with `config :homelab, :migrate_copy_engine,
  Homelab.Deployments.Migrate.ContainerCopyEngine`.
  """

  @behaviour Homelab.Deployments.Migrate.CopyEngine

  require Logger

  alias Homelab.Docker.Client

  @default_image "alpine:3.20"
  # The DB cold-copy of a large dir can take minutes; give the wait room.
  @wait_timeout 1_800_000

  @impl true
  def migrate(source, dest, _opts \\ []) do
    image = helper_image()

    with :ok <- ensure_image(image),
         {:ok, id} <- create(image, source, dest) do
      result = run_and_collect(id)
      _ = remove(id)
      result
    end
  end

  # --- pure helpers (unit-tested) -------------------------------------------

  @doc "The host bind specs mounting the source read-only and the dest writable."
  def binds(source, dest), do: ["#{source}:/src:ro", "#{dest}:/dest"]

  @doc """
  The in-container script: clear dest, `cp -a` (ownership-preserving) the source
  in, checksum both trees, and fail with exit 3 if they differ. Prints a RESULT
  line the engine parses.
  """
  def build_script do
    """
    set -eu
    rm -rf /dest/* /dest/.[!.]* 2>/dev/null || true
    cp -a /src/. /dest/
    cd /src && find . -type f -exec sha256sum {} ';' | sort > /tmp/s
    cd /dest && find . -type f -exec sha256sum {} ';' | sort > /tmp/d
    diff /tmp/s /tmp/d >/dev/null || { echo VERIFY_MISMATCH; exit 3; }
    echo "RESULT files=$(wc -l < /tmp/s) kbytes=$(du -sk /src | cut -f1) digest=$(sha256sum < /tmp/s | cut -d' ' -f1)"
    """
  end

  @doc "Parses the helper's RESULT line into a proof map, or `:error`."
  def parse_result(log) when is_binary(log) do
    case Regex.run(~r/RESULT files=(\d+) kbytes=(\d+) digest=([0-9a-f]+)/, log) do
      [_, files, kbytes, digest] ->
        kb = String.to_integer(kbytes)

        {:ok,
         %{
           "files" => String.to_integer(files),
           "bytes" => kb * 1024,
           "kbytes" => kb,
           "digest" => digest,
           "verified" => true
         }}

      _ ->
        :error
    end
  end

  # --- daemon orchestration -------------------------------------------------

  defp run_and_collect(id) do
    with :ok <- start(id),
         {:ok, status} <- wait(id),
         {:ok, log} <- logs(id) do
      interpret(status, log)
    end
  end

  defp interpret(0, log) do
    case parse_result(log) do
      {:ok, proof} -> {:ok, proof}
      :error -> {:error, {:helper_no_result, log}}
    end
  end

  defp interpret(3, _log), do: {:error, {:verify_mismatch, :container}}

  defp interpret(status, log),
    do: {:error, {:helper_failed, status, String.slice(log, -2000, 2000)}}

  defp create(image, source, dest) do
    body = %{
      "Image" => image,
      "Cmd" => ["/bin/sh", "-c", build_script()],
      "Tty" => true,
      "HostConfig" => %{"Binds" => binds(source, dest), "AutoRemove" => false}
    }

    case Client.post("/containers/create", body) do
      {:ok, %{"Id" => id}} -> {:ok, id}
      {:error, reason} -> {:error, {:create_failed, reason}}
    end
  end

  defp start(id) do
    case Client.post("/containers/#{id}/start") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp wait(id) do
    case Client.post("/containers/#{id}/wait", nil, receive_timeout: @wait_timeout) do
      {:ok, %{"StatusCode" => code}} -> {:ok, code}
      {:error, reason} -> {:error, {:wait_failed, reason}}
    end
  end

  defp logs(id) do
    case Client.get("/containers/#{id}/logs?stdout=true&stderr=true") do
      {:ok, body} when is_binary(body) -> {:ok, body}
      {:ok, _} -> {:ok, ""}
      {:error, reason} -> {:error, {:logs_failed, reason}}
    end
  end

  defp remove(id), do: Client.delete("/containers/#{id}?force=true")

  defp ensure_image(image) do
    case Client.get("/images/#{image}/json") do
      {:ok, _} -> :ok
      {:error, {:not_found, _}} -> pull(image)
      {:error, reason} -> {:error, {:image_inspect_failed, reason}}
    end
  end

  defp pull(image) do
    {name, tag} = split_image(image)
    Logger.info("[container_copy] pulling helper image #{image}")

    case Client.post_stream("/images/create?fromImage=#{name}&tag=#{tag}") do
      :ok -> :ok
      {:error, reason} -> {:error, {:image_pull_failed, reason}}
    end
  end

  defp split_image(image) do
    case String.split(image, ":", parts: 2) do
      [name, tag] -> {name, tag}
      [name] -> {name, "latest"}
    end
  end

  defp helper_image, do: Application.get_env(:homelab, :migrate_helper_image, @default_image)
end
