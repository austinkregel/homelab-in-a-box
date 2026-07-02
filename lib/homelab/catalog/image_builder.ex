defmodule Homelab.Catalog.ImageBuilder do
  @moduledoc """
  Builds a Docker image from an in-Workbench build context: a Dockerfile plus
  any number of supporting text files authored in the UI.

  The files are written to a throwaway temp directory, packed into a gzip'd tar
  context with the built-in `:erl_tar`, and streamed to the daemon's `/build`
  endpoint via `Homelab.Docker.Client.build/3`. Each decoded build event is
  forwarded to `on_event` so callers can surface live build logs.

  Built images are tagged in the `homelab-built/` namespace. When the self-hosted
  registry is configured, the image is retagged under `registry.<base_domain>/`
  and pushed so Swarm nodes can pull it; otherwise it stays local-only and the
  deploy path skips the pull.
  """

  alias Homelab.Config
  alias Homelab.Docker.Client
  alias Homelab.Docker.RegistryAuth

  @doc """
  Builds an image from `files` (a list of `%{name: String.t(), content: String.t()}`,
  one of which must be `"Dockerfile"`) tagged as `opts[:tag]`.

  Forwards every build event to `on_event` and returns `{:ok, tag}` on success
  or `{:error, reason}` on failure.
  """
  def build(files, opts, on_event) when is_list(files) and is_function(on_event, 1) do
    tag = Keyword.fetch!(opts, :tag)

    with :ok <- validate_files(files) do
      root = Path.join(System.tmp_dir!(), "homelab-build-#{System.unique_integer([:positive])}")
      tar_path = root <> ".tar.gz"

      try do
        File.mkdir_p!(root)
        write_context(root, files)

        entries =
          Enum.map(files, fn %{name: name} ->
            {String.to_charlist(name), String.to_charlist(Path.join(root, name))}
          end)

        case :erl_tar.create(tar_path, entries, [:compressed]) do
          :ok ->
            query = "t=#{URI.encode(tag)}&dockerfile=Dockerfile"

            case Client.build(query, File.read!(tar_path), on_event) do
              :ok -> maybe_publish(tag, on_event)
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, {:context_failed, reason}}
        end
      after
        File.rm_rf(root)
        File.rm(tar_path)
      end
    end
  end

  # After a successful local build, push to the self-hosted registry when
  # configured (retag under registry.<base_domain>/ and push, returning the
  # registry ref). Otherwise keep the local `homelab-built/...` ref.
  defp maybe_publish(local_tag, on_event) do
    if Config.registry_configured?() do
      registry_ref = "#{Config.registry_ref_prefix()}/#{local_tag}"

      with :ok <- retag(local_tag, registry_ref),
           :ok <- push(registry_ref, on_event) do
        {:ok, registry_ref}
      end
    else
      {:ok, local_tag}
    end
  end

  defp retag(source, target) do
    {repo, tag} = split_ref(target)

    case Client.post(
           "/images/#{URI.encode(source)}/tag?repo=#{URI.encode(repo)}&tag=#{URI.encode(tag)}"
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:tag_failed, reason}}
    end
  end

  defp push(registry_ref, on_event) do
    case Config.registry_credentials() do
      {username, password} ->
        header = RegistryAuth.header(%{username: username, password: password})
        Client.push(registry_ref, headers: [header], on_event: on_event)

      nil ->
        {:error, :missing_credentials}
    end
  end

  # Splits "registry.host/homelab-built/app:1.0" into {"registry.host/homelab-built/app", "1.0"}.
  # Our registry refs never contain a host port, so the single ":" is the tag.
  defp split_ref(ref) do
    case String.split(ref, ":", parts: 2) do
      [repo, tag] -> {repo, tag}
      [repo] -> {repo, "latest"}
    end
  end

  defp validate_files(files) do
    cond do
      not Enum.any?(files, &(&1.name == "Dockerfile")) ->
        {:error, :missing_dockerfile}

      Enum.any?(files, &(String.trim(&1.name) == "")) ->
        {:error, :unnamed_file}

      true ->
        :ok
    end
  end

  defp write_context(root, files) do
    Enum.each(files, fn %{name: name, content: content} ->
      path = Path.join(root, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content || "")
    end)
  end
end
