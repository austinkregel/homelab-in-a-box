defmodule Homelab.Backups.Targets.LocalDisk do
  @moduledoc """
  Archives on a filesystem the operator chose.

  The root is required. It raises when unset, the way
  `Homelab.Deployments.PermanentHome.managed_root/0` does, rather than falling back to
  `System.tmp_dir!()` — which is what the release gate does today, putting the
  pre-cutover safety copy in the container's own `/tmp` where a restart erases it.

  A local target protects against losing a volume, not against losing the machine. It
  is the fast path and the one that always works; an off-box target is what survives
  the host.
  """

  @behaviour Homelab.Backups.Target

  @frames_dir "frames"

  @impl true
  def kind, do: "local_disk"

  @impl true
  def display_name, do: "Local disk"

  @impl true
  def open(config, key, _opts \\ []) do
    dir = object_dir(config, key)

    with :ok <- File.mkdir_p(Path.join(dir, @frames_dir)) do
      {:ok, %{dir: dir, index: 0, bytes: 0}}
    end
  end

  @impl true
  def write(%{dir: dir, index: index, bytes: bytes} = handle, frame) do
    path = frame_path(dir, index)
    data = IO.iodata_to_binary(frame)

    case File.write(path, data) do
      :ok -> {:ok, %{handle | index: index + 1, bytes: bytes + byte_size(data)}}
      {:error, reason} -> {:error, {:write_failed, path, reason}}
    end
  end

  @impl true
  def close(%{bytes: bytes, index: index}) do
    {:ok, %{bytes: bytes, frames: index}}
  end

  @impl true
  def abort(%{dir: dir}) do
    File.rm_rf(dir)
    :ok
  end

  @impl true
  def read_stream(config, key, _opts \\ []) do
    dir = object_dir(config, key)

    case File.ls(Path.join(dir, @frames_dir)) do
      {:ok, entries} ->
        {:ok,
         entries
         |> Enum.map(&frame_index/1)
         |> Enum.reject(&is_nil/1)
         |> Enum.sort()
         |> Stream.map(&File.read!(frame_path(dir, &1)))}

      {:error, reason} ->
        {:error, {:not_found, key, reason}}
    end
  end

  @impl true
  def stat(config, key) do
    dir = Path.join(object_dir(config, key), @frames_dir)

    case File.ls(dir) do
      {:ok, entries} ->
        bytes =
          entries
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.map(fn path ->
            case File.stat(path) do
              {:ok, %File.Stat{size: size}} -> size
              _ -> 0
            end
          end)
          |> Enum.sum()

        {:ok, %{bytes: bytes, frames: length(entries)}}

      {:error, reason} ->
        {:error, {:not_found, key, reason}}
    end
  end

  @impl true
  def list(config, prefix) do
    root = root!(config)
    search = Path.join(root, prefix)

    case File.ls(search) do
      {:ok, entries} ->
        {:ok,
         entries
         |> Enum.map(&Path.join(prefix, &1))
         |> Enum.map(fn key ->
           case stat(config, key) do
             {:ok, meta} -> Map.put(meta, :key, key)
             {:error, _} -> nil
           end
         end)
         |> Enum.reject(&is_nil/1)}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete(config, key) do
    case File.rm_rf(object_dir(config, key)) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  @doc "The configured root, raising when the operator has not chosen one."
  def root!(config) do
    case Map.get(config, :root) || Map.get(config, "root") do
      root when is_binary(root) and root != "" ->
        if Path.type(root) == :absolute do
          root
        else
          raise ArgumentError, """
          The backup root must be an absolute host path, got #{inspect(root)}.

          A relative root resolves against whatever directory this process happens to
          be running in, which is not a location anybody chose to keep backups.
          """
        end

      _ ->
        raise ArgumentError, """
        No backup root is configured for the local target.

        Every archive written here would otherwise land in a temporary directory that
        the next container restart erases. Set one under Settings -> Backups, and make
        sure it is bind-mounted into this container.
        """
    end
  end

  defp object_dir(config, key), do: Path.join(root!(config), key)

  defp frame_path(dir, index),
    do: Path.join([dir, @frames_dir, index |> Integer.to_string() |> String.pad_leading(8, "0")])

  defp frame_index(name) do
    case Integer.parse(name) do
      {index, ""} -> index
      _ -> nil
    end
  end
end
