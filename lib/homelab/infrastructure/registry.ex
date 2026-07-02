defmodule Homelab.Infrastructure.Registry do
  @moduledoc """
  Provisions the self-hosted Docker registry as two system containers:

    * `homelab-registry` — read-write, htpasswd-authenticated push target at
      `registry.<base_domain>`. Swarm nodes pull built/pushed images from here.
    * `homelab-registry-proxy` — a read-only pull-through cache of Docker Hub at
      `proxy-registry.<base_domain>`. Nodes opt in via a one-time `daemon.json`
      `registry-mirrors` entry.

  Both are fronted by the existing Traefik (via container labels) and covered by
  the wildcard `*.<base_domain>` cert. A registry in proxy mode cannot accept
  pushes, which is why the push target and the mirror are separate containers.
  """

  require Logger

  alias Homelab.Config
  alias Homelab.Docker.Client
  alias Homelab.Infrastructure
  alias Homelab.Infrastructure.Htpasswd

  @registry_name "homelab-registry"
  @proxy_name "homelab-registry-proxy"
  @auth_path "/auth"

  @doc "Delegates to `Homelab.Config.registry_configured?/0`."
  def configured?, do: Config.registry_configured?()

  @doc """
  Provisions (or re-provisions) the read-write registry: generates the htpasswd
  file from the stored credentials, creates the container, uploads the auth file,
  starts it, wires Traefik, and best-effort creates the DNS record.
  """
  def ensure_registry do
    case Config.registry_credentials() do
      {username, password} ->
        with :ok <- Infrastructure.ensure_internal_network(),
             {:ok, htpasswd} <- Htpasswd.generate(username, password),
             :ok <- recreate_registry(htpasswd) do
          Infrastructure.connect_traefik_to_network(Infrastructure.internal_network())
          ensure_dns_record("registry.#{Config.base_domain()}")
          {:ok, :started}
        end

      nil ->
        {:error, :missing_credentials}
    end
  end

  @doc "Provisions (or re-provisions) the pull-through Docker Hub mirror."
  def ensure_registry_proxy do
    with :ok <- Infrastructure.ensure_internal_network(),
         {:ok, _} <- pull_registry_image(),
         {:ok, %{"Id" => id}} <-
           Client.post("/containers/create?name=#{@proxy_name}", proxy_payload()),
         {:ok, _} <- Client.post("/containers/#{id}/start") do
      Infrastructure.connect_traefik_to_network(Infrastructure.internal_network())
      ensure_dns_record("proxy-registry.#{Config.base_domain()}")
      {:ok, :started}
    else
      {:error, {:conflict, _}} ->
        _ = Client.delete("/containers/#{@proxy_name}?force=true")
        ensure_registry_proxy()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Stops and removes both registry containers (does not delete data volumes)."
  def teardown do
    _ = Client.delete("/containers/#{@registry_name}?force=true")
    _ = Client.delete("/containers/#{@proxy_name}?force=true")
    :ok
  end

  # --- internals ---

  # Recreate the RW registry: create (not started) → upload htpasswd → start.
  defp recreate_registry(htpasswd) do
    _ = Client.delete("/containers/#{@registry_name}?force=true")

    with {:ok, _} <- pull_registry_image(),
         {:ok, %{"Id" => id}} <-
           Client.post("/containers/create?name=#{@registry_name}", registry_payload()),
         :ok <- Client.upload_archive(id, @auth_path, htpasswd_tar(htpasswd)),
         {:ok, _} <- Client.post("/containers/#{id}/start") do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp pull_registry_image do
    case Client.post_stream("/images/create?fromImage=registry:2") do
      :ok -> {:ok, :pulled}
      {:error, reason} -> {:error, {:pull_failed, reason}}
    end
  end

  defp registry_payload do
    %{
      "Image" => "registry:2",
      "Env" => [
        "REGISTRY_AUTH=htpasswd",
        "REGISTRY_AUTH_HTPASSWD_REALM=Registry Realm",
        "REGISTRY_AUTH_HTPASSWD_PATH=#{@auth_path}/htpasswd",
        "REGISTRY_STORAGE_DELETE_ENABLED=true"
      ],
      "Labels" => registry_labels("registry", "registry.#{Config.base_domain()}"),
      "HostConfig" => %{
        "NetworkMode" => Infrastructure.internal_network(),
        "RestartPolicy" => %{"Name" => "unless-stopped"},
        "Mounts" => [
          %{
            "Type" => "volume",
            "Source" => "homelab-registry-data",
            "Target" => "/var/lib/registry"
          },
          %{"Type" => "volume", "Source" => "homelab-registry-auth", "Target" => @auth_path}
        ]
      }
    }
  end

  defp proxy_payload do
    env =
      [
        "REGISTRY_PROXY_REMOTEURL=#{Homelab.Settings.get("registry_mirror_upstream", "https://registry-1.docker.io")}"
      ] ++ proxy_upstream_auth()

    %{
      "Image" => "registry:2",
      "Env" => env,
      "Labels" => registry_labels("registryproxy", "proxy-registry.#{Config.base_domain()}"),
      "HostConfig" => %{
        "NetworkMode" => Infrastructure.internal_network(),
        "RestartPolicy" => %{"Name" => "unless-stopped"},
        "Mounts" => [
          %{
            "Type" => "volume",
            "Source" => "homelab-registry-proxy-data",
            "Target" => "/var/lib/registry"
          }
        ]
      }
    }
  end

  defp proxy_upstream_auth do
    user = Homelab.Settings.get("registry_mirror_username")
    pass = Homelab.Settings.get("registry_mirror_password")

    if is_binary(user) and user != "" and is_binary(pass) and pass != "" do
      ["REGISTRY_PROXY_USERNAME=#{user}", "REGISTRY_PROXY_PASSWORD=#{pass}"]
    else
      []
    end
  end

  # Traefik Docker-provider routing labels. The wildcard cert covers the host, so
  # only the router rule/entrypoint/certresolver + service port are needed. The
  # explicit tls.domains asks Traefik to obtain the wildcard up front.
  defp registry_labels(router, host) do
    base_domain = Config.base_domain()

    %{
      Infrastructure.system_label() => "true",
      "homelab.system.role" =>
        if(router == "registryproxy", do: "registry-mirror", else: "registry"),
      "traefik.enable" => "true",
      "traefik.http.routers.#{router}.rule" => "Host(`#{host}`)",
      "traefik.http.routers.#{router}.entrypoints" => "websecure",
      "traefik.http.routers.#{router}.tls" => "true",
      "traefik.http.routers.#{router}.tls.certresolver" => "letsencrypt",
      "traefik.http.routers.#{router}.tls.domains[0].main" => base_domain,
      "traefik.http.routers.#{router}.tls.domains[0].sans" => "*.#{base_domain}",
      "traefik.http.services.#{router}.loadbalancer.server.port" => "5000"
    }
  end

  # Uncompressed tar with a single `htpasswd` entry (the archive endpoint wants a
  # plain tar). Built via a temp file, mirroring the pattern in image_builder.ex.
  defp htpasswd_tar(htpasswd_line) do
    dir = Path.join(System.tmp_dir!(), "homelab-htpasswd-#{System.unique_integer([:positive])}")
    tar_path = dir <> ".tar"

    try do
      File.mkdir_p!(dir)
      file = Path.join(dir, "htpasswd")
      File.write!(file, htpasswd_line)
      :ok = :erl_tar.create(tar_path, [{~c"htpasswd", String.to_charlist(file)}], [])
      File.read!(tar_path)
    after
      File.rm_rf(dir)
      File.rm(tar_path)
    end
  end

  # Best-effort DNS A record for a registry hostname; the operator can also
  # manage records manually (e.g. a wildcard). Requires an operator-provided
  # `registry_host_ip` — skipped with a log otherwise.
  defp ensure_dns_record(fqdn) do
    case Homelab.Settings.get("registry_host_ip") do
      ip when is_binary(ip) and ip != "" ->
        Homelab.Networking.ensure_system_dns_record(fqdn, %{public_ip: ip})

      _ ->
        Logger.info(
          "Infrastructure.Registry: registry_host_ip unset; create the #{fqdn} A record manually"
        )

        {:ok, []}
    end
  end
end
