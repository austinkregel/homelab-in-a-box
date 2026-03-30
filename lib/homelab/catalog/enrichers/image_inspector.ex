defmodule Homelab.Catalog.Enrichers.ImageInspector do
  @moduledoc """
  Inspects Docker images via the Registry V2 API to extract metadata
  (ExposedPorts, Volumes, Env, Labels) without pulling the full image.

  Supports Docker Hub, GHCR, lscr.io (proxied Docker Hub), and ECR Public.
  """

  require Logger

  @docker_hub_registry "https://registry-1.docker.io"
  @docker_hub_auth "https://auth.docker.io"
  @ghcr_registry "https://ghcr.io"
  @ecr_registry "https://public.ecr.aws"

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

    with {:ok, token} <- fetch_auth_token(auth_url, repo),
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

    {registry_url, auth_url, rest} =
      cond do
        String.starts_with?(ref, "ghcr.io/") ->
          {@ghcr_registry, @ghcr_registry, String.trim_leading(ref, "ghcr.io/")}

        String.starts_with?(ref, "lscr.io/") ->
          {@docker_hub_registry, @docker_hub_auth, String.trim_leading(ref, "lscr.io/")}

        String.starts_with?(ref, "public.ecr.aws/") ->
          {@ecr_registry, nil, String.trim_leading(ref, "public.ecr.aws/")}

        String.starts_with?(ref, "docker.io/") ->
          {@docker_hub_registry, @docker_hub_auth, String.trim_leading(ref, "docker.io/")}

        String.contains?(ref, "/") ->
          {@docker_hub_registry, @docker_hub_auth, ref}

        true ->
          {@docker_hub_registry, @docker_hub_auth, "library/#{ref}"}
      end

    {repo, tag} =
      case String.split(rest, ":", parts: 2) do
        [r, t] -> {r, t}
        [r] -> {r, "latest"}
      end

    {registry_url, auth_url, repo, tag}
  end

  defp fetch_auth_token(nil, _repo), do: {:ok, nil}

  defp fetch_auth_token(auth_url, repo) do
    token_url =
      cond do
        auth_url == @docker_hub_auth ->
          "#{auth_url}/token?service=registry.docker.io&scope=repository:#{repo}:pull"

        auth_url == @ghcr_registry ->
          "#{auth_url}/token?service=ghcr.io&scope=repository:#{repo}:pull"

        true ->
          "#{auth_url}/token?scope=repository:#{repo}:pull"
      end

    case Req.get(token_url, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:auth_failed, status, body}}

      {:error, reason} ->
        {:error, {:auth_request_failed, reason}}
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

  @doc false
  def parse_exposed_ports(ports) when is_map(ports) do
    Enum.map(ports, fn {port_spec, _} ->
      port_num =
        port_spec
        |> String.split("/")
        |> List.first()

      %{
        "internal" => port_num,
        "external" => port_num,
        "description" => nil,
        "optional" => false,
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
