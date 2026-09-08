defmodule Homelab.Catalog.Enrichers.ImageInspector do
  @moduledoc """
  Inspects Docker images via the Registry V2 API to extract metadata
  (ExposedPorts, Volumes, Env, Labels) without pulling the full image.

  Supports Docker Hub, GHCR, lscr.io (proxied Docker Hub), ECR Public, and any
  other Registry V2 host named in the reference — including the self-hosted
  registry at `Homelab.Config.registry_ref_prefix/0`.
  """

  require Logger

  @docker_hub_registry "https://registry-1.docker.io"
  @docker_hub_auth "https://auth.docker.io"
  @ghcr_registry "https://ghcr.io"
  @ecr_registry "https://public.ecr.aws"

  # Hosts that are all names for Docker Hub's Registry V2 endpoint, plus lscr.io,
  # which proxies it.
  @docker_hub_hosts ~w(docker.io index.docker.io registry-1.docker.io lscr.io)

  @manifest_v2 "application/vnd.docker.distribution.manifest.v2+json"
  @manifest_list "application/vnd.docker.distribution.manifest.list.v2+json"
  @oci_manifest "application/vnd.oci.image.manifest.v1+json"
  @oci_index "application/vnd.oci.image.index.v1+json"

  @type enrichment_result :: %{
          ports: [map()],
          volumes: [map()],
          env: [map()],
          labels: map()
        }

  @spec inspect(String.t()) :: {:ok, enrichment_result()} | {:error, term()}
  def inspect(full_ref) when is_binary(full_ref) do
    {registry_url, auth_url, repo, tag} = parse_image_ref(full_ref)
    Logger.info("[ImageInspector] Inspecting #{full_ref} → #{registry_url}/#{repo}:#{tag}")

    with {:ok, token} <- fetch_auth_token(auth_url, repo, full_ref),
         {:ok, config_digest} <- fetch_manifest(registry_url, repo, tag, token),
         {:ok, config} <- fetch_config_blob(registry_url, repo, config_digest, token) do
      result = extract_metadata(config)

      Logger.info(
        "[ImageInspector] #{full_ref}: #{length(result.env)} env, #{length(result.ports)} ports, #{length(result.volumes)} volumes"
      )

      {:ok, result}
    else
      {:error, reason} = err ->
        Logger.warning(
          "[ImageInspector] Failed to inspect #{full_ref}: #{Kernel.inspect(reason)}"
        )

        err
    end
  rescue
    e ->
      Logger.warning("[ImageInspector] Exception inspecting #{full_ref}: #{Exception.message(e)}")
      {:error, {:inspect_failed, Exception.message(e)}}
  end

  @doc false
  def parse_image_ref(ref) do
    ref = String.trim(ref)

    {host, path} = split_registry_host(ref)
    {registry_url, auth_url} = registry_for(host)
    {repo, tag} = split_repo_tag(path)

    repo = if host == nil and not String.contains?(repo, "/"), do: "library/#{repo}", else: repo

    {registry_url, auth_url, repo, tag}
  end

  # The first segment is a registry host, not a Docker Hub namespace, only when it
  # looks like one: it carries a dot (`registry.example.com`), carries a port
  # (`host:5000`), or is literally `localhost`. `linuxserver/nextcloud` has none of
  # those, so it stays a Hub namespace.
  defp split_registry_host(ref) do
    case String.split(ref, "/", parts: 2) do
      [first, path] ->
        if registry_host?(first), do: {first, path}, else: {nil, ref}

      [_] ->
        {nil, ref}
    end
  end

  defp registry_host?(segment) do
    segment == "localhost" or String.contains?(segment, ".") or String.contains?(segment, ":")
  end

  defp registry_for(nil), do: {docker_hub_registry(), docker_hub_auth()}
  defp registry_for("ghcr.io"), do: {ghcr_registry(), ghcr_registry()}
  defp registry_for("public.ecr.aws"), do: {ecr_registry(), nil}

  defp registry_for(host) when host in @docker_hub_hosts,
    do: {docker_hub_registry(), docker_hub_auth()}

  # Any other host is its own Registry V2 endpoint, and issues its own tokens. This
  # is the path the self-hosted registry (`Homelab.Config.registry_ref_prefix/0`)
  # takes.
  defp registry_for(host) do
    url = registry_scheme(host) <> host
    {url, url}
  end

  # Loopback registries are served over plain HTTP, the same default Docker applies
  # to them.
  defp registry_scheme("localhost"), do: "http://"
  defp registry_scheme("localhost:" <> _), do: "http://"
  defp registry_scheme("127.0.0.1" <> _), do: "http://"
  defp registry_scheme(_), do: "https://"

  # A tag can only follow the LAST "/". Splitting the whole path on its first colon
  # instead would read the port out of `host:5000/library/alpine:latest` as the tag.
  defp split_repo_tag(path) do
    {prefix, name} =
      case String.split(path, "/") do
        [name] -> {"", name}
        segments -> {Enum.join(Enum.drop(segments, -1), "/") <> "/", List.last(segments)}
      end

    case String.split(name, ":") do
      [name] -> {prefix <> name, "latest"}
      parts -> {prefix <> Enum.join(Enum.drop(parts, -1), ":"), List.last(parts)}
    end
  end

  defp endpoints, do: Application.get_env(:homelab, __MODULE__, [])

  defp docker_hub_registry, do: endpoints()[:docker_hub_url] || @docker_hub_registry
  defp docker_hub_auth, do: endpoints()[:docker_hub_auth_url] || @docker_hub_auth
  defp ghcr_registry, do: endpoints()[:ghcr_url] || @ghcr_registry
  defp ecr_registry, do: endpoints()[:ecr_url] || @ecr_registry

  defp fetch_auth_token(nil, _repo, _full_ref), do: {:ok, nil}

  defp fetch_auth_token(auth_url, repo, full_ref) do
    token_url =
      cond do
        auth_url == docker_hub_auth() ->
          "#{auth_url}/token?service=registry.docker.io&scope=repository:#{repo}:pull"

        auth_url == ghcr_registry() ->
          "#{auth_url}/token?service=ghcr.io&scope=repository:#{repo}:pull"

        true ->
          "#{auth_url}/token?scope=repository:#{repo}:pull"
      end

    opts = [receive_timeout: 10_000] ++ basic_auth(full_ref)

    case Req.get(token_url, opts) do
      {:ok, %{status: 200, body: %{"token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        token_service_declined(auth_url, status, body)

      {:error, reason} ->
        {:error, {:auth_request_failed, reason}}
    end
  end

  # Docker Hub and GHCR always run a token service, so anything but a token from
  # them is the real failure and stops the walk here. A self-hosted or third-party
  # registry need not run one at all — a plain Registry V2 serves manifests
  # anonymously — so there we carry on unauthenticated and let the manifest
  # request be the one that reports a 401.
  defp token_service_declined(auth_url, status, body) do
    if auth_url in [docker_hub_auth(), ghcr_registry()] do
      {:error, {:auth_failed, status, body}}
    else
      {:ok, nil}
    end
  end

  # The token endpoint hands out an ANONYMOUS token to an unauthenticated request
  # even for a private repo — it just isn't valid for it, so the failure only shows
  # up later as a 401/403 ("invalid token") on the manifest. Present the registry
  # credentials here so the token comes back scoped to the private repo.
  defp basic_auth(full_ref) do
    case Homelab.Docker.RegistryAuth.auth_config_for_ref(full_ref) do
      %{"username" => username, "password" => password} ->
        [auth: {:basic, "#{username}:#{password}"}]

      _ ->
        []
    end
  end

  defp fetch_manifest(registry_url, repo, tag, token) do
    url = "#{registry_url}/v2/#{repo}/manifests/#{tag}"

    accept =
      Enum.join([@manifest_v2, @manifest_list, @oci_manifest, @oci_index], ", ")

    headers = [{"accept", accept}]
    headers = if token, do: [{"authorization", "Bearer #{token}"} | headers], else: headers

    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"config" => %{"digest" => digest}}}} ->
        {:ok, digest}

      {:ok, %{status: 200, body: %{"manifests" => manifests}}} when is_list(manifests) ->
        resolve_manifest_list(registry_url, repo, manifests, token)

      {:ok, %{status: status, body: body}} ->
        {:error, {:manifest_failed, status, body}}

      {:error, reason} ->
        {:error, {:manifest_request_failed, reason}}
    end
  end

  defp resolve_manifest_list(registry_url, repo, manifests, token) do
    preferred =
      Enum.find(manifests, fn m ->
        platform = m["platform"] || %{}
        platform["architecture"] == "amd64" and platform["os"] == "linux"
      end) ||
        Enum.find(manifests, fn m ->
          platform = m["platform"] || %{}
          platform["os"] == "linux"
        end) ||
        List.first(manifests)

    case preferred do
      %{"digest" => digest} ->
        url = "#{registry_url}/v2/#{repo}/manifests/#{digest}"
        headers = [{"accept", @manifest_v2 <> ", " <> @oci_manifest}]
        headers = if token, do: [{"authorization", "Bearer #{token}"} | headers], else: headers

        case Req.get(url, headers: headers, receive_timeout: 15_000) do
          {:ok, %{status: 200, body: %{"config" => %{"digest" => config_digest}}}} ->
            {:ok, config_digest}

          {:ok, %{status: status, body: body}} ->
            {:error, {:manifest_failed, status, body}}

          {:error, reason} ->
            {:error, {:manifest_request_failed, reason}}
        end

      nil ->
        {:error, :no_manifests_found}
    end
  end

  defp fetch_config_blob(registry_url, repo, digest, token) do
    url = "#{registry_url}/v2/#{repo}/blobs/#{digest}"
    headers = [{"accept", "application/vnd.docker.container.image.v1+json"}]
    headers = if token, do: [{"authorization", "Bearer #{token}"} | headers], else: headers

    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, {:blob_not_json, String.slice(body, 0, 200)}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:blob_failed, status, body}}

      {:error, reason} ->
        {:error, {:blob_request_failed, reason}}
    end
  end

  @doc false
  def extract_metadata(config) do
    container_config = config["config"] || config["container_config"] || %{}

    ports = parse_exposed_ports(container_config["ExposedPorts"])
    volumes = parse_volumes(container_config["Volumes"])
    env = parse_env(container_config["Env"])
    labels = container_config["Labels"] || %{}

    %{ports: ports, volumes: volumes, env: env, labels: labels}
  end

  @doc false
  def parse_exposed_ports(nil), do: []

  # ExposedPorts keys are `"<port>/<proto>"`, and the proto half is kept rather than
  # split off and dropped. An image declaring `EXPOSE 27900/udp` previously enriched to
  # a TCP port map — the number looked right in the UI, so the loss was invisible until
  # the deployed container turned out to be unreachable.
  @doc false
  def parse_exposed_ports(ports) when is_map(ports) do
    Enum.map(ports, fn {port_spec, _} ->
      {port_num, protocol} =
        case String.split(port_spec, "/", parts: 2) do
          [num, "udp"] -> {num, "udp"}
          [num | _] -> {num, "tcp"}
        end

      %{
        "internal" => port_num,
        "external" => port_num,
        "description" => nil,
        "optional" => false,
        "protocol" => protocol,
        "role" => Homelab.Catalog.Enrichers.PortRoles.infer(port_num)
      }
    end)
  end

  @doc false
  def parse_volumes(nil), do: []

  @doc false
  def parse_volumes(volumes) when is_map(volumes) do
    Enum.map(volumes, fn {path, _} ->
      %{
        "path" => path,
        "description" => nil,
        "optional" => false
      }
    end)
  end

  @doc false
  def parse_env(nil), do: []

  @doc false
  def parse_env(env_list) when is_list(env_list) do
    env_list
    |> Enum.map(fn env_str ->
      case String.split(env_str, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
    |> Enum.reject(fn {key, _} -> system_env?(key) end)
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => value} end)
  end

  @system_env_prefixes ~w(PATH HOME HOSTNAME LANG LC_ TERM SHLVL _ GOPATH JAVA_HOME
                          S6_ PS1 VIRTUAL_ENV PHP_INI LSIO_ GPG_KEY PYTHON
                          NVIDIA_ DOTNET_ ASPNET NODE_VERSION YARN_VERSION
                          PHPIZE_DEPS PHP_CFLAGS PHP_VERSION)

  @system_env_exact ~w(MEMORY_LIMIT LSIO_FIRST_PARTY)

  @doc false
  def system_env?(key) do
    key in @system_env_exact or
      Enum.any?(@system_env_prefixes, fn prefix -> String.starts_with?(key, prefix) end)
  end
end
