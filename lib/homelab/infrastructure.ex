defmodule Homelab.Infrastructure do
  @moduledoc """
  Manages system-level infrastructure services (reverse proxy, DNS, auth providers).
  These are deployed as regular containers but tagged as system services.
  """

  require Logger
  alias Homelab.Docker.Client

  @system_label "homelab.system"
  @network "homelab-internal"

  @system_templates %{
    "traefik" => %{
      name: "Traefik",
      image: "traefik:v3.6",
      ports: [
        %{"host" => 80, "container" => 80},
        %{"host" => 443, "container" => 443},
        %{"host" => 8080, "container" => 8080}
      ],
      volumes: [
        %{
          "source" => "/var/run/docker.sock",
          "target" => "/var/run/docker.sock",
          "type" => "bind"
        },
        %{
          "source" => "homelab-traefik-certs",
          "target" => "/letsencrypt",
          "type" => "volume"
        }
      ],
      command: [
        "--api.insecure=true",
        "--providers.docker=true",
        "--providers.docker.exposedbydefault=false",
        "--entryPoints.web.address=:80",
        "--entryPoints.websecure.address=:443",
        "--entryPoints.web.http.redirections.entryPoint.to=websecure",
        "--entryPoints.web.http.redirections.entryPoint.scheme=https",
        "--certificatesresolvers.letsencrypt.acme.httpchallenge=true",
        "--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web",
        "--certificatesresolvers.letsencrypt.acme.storage=/letsencrypt/acme.json",
        "--metrics.prometheus=true",
        "--metrics.prometheus.addRoutersLabels=true",
        "--metrics.prometheus.addServicesLabels=true"
      ],
      labels: %{
        @system_label => "true",
        "homelab.system.role" => "reverse-proxy"
      }
    },
    "pihole" => %{
      name: "Pi-hole",
      image: "pihole/pihole:latest",
      env: ["TZ=UTC"],
      ports: [%{"host" => 53, "container" => 53}, %{"host" => 8053, "container" => 80}],
      volumes: [
        %{"source" => "homelab-pihole-etc", "target" => "/etc/pihole", "type" => "volume"},
        %{"source" => "homelab-pihole-dns", "target" => "/etc/dnsmasq.d", "type" => "volume"}
      ],
      command: [],
      labels: %{
        @system_label => "true",
        "homelab.system.role" => "dns"
      }
    }
  }

  def list_system_services do
    case Client.get(
           "/containers/json?all=true&filters=#{URI.encode_www_form(Jason.encode!(%{"label" => ["#{@system_label}=true"]}))}"
         ) do
      {:ok, containers} when is_list(containers) ->
        {:ok,
         Enum.map(containers, fn c ->
           %{
             id: c["Id"],
             name: c["Names"] |> List.first() |> String.trim_leading("/"),
             image: c["Image"],
             status: c["State"],
             role: get_in(c, ["Labels", "homelab.system.role"]) || "unknown"
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Idempotently ensures Traefik is running. Returns `{:ok, :already_running}`
  or `{:ok, :started}` on success.
  """
  def ensure_traefik do
    template = Map.fetch!(@system_templates, "traefik")

    acme_email =
      Homelab.Settings.get("acme_email") ||
        Homelab.Settings.get("base_domain", "admin@homelab.local")

    acme_cmd = "--certificatesresolvers.letsencrypt.acme.email=#{acme_email}"
    template = Map.update!(template, :command, &(&1 ++ [acme_cmd]))

    with :ok <- ensure_network(@network),
         result when result in [{:ok, :already_running}, {:ok, :started}] <-
           provision_template("homelab-traefik", template) do
      sync_traefik_networks()
      result
    end
  end

  def provision_service(service_key) when is_map_key(@system_templates, service_key) do
    template = Map.fetch!(@system_templates, service_key)
    container_name = "homelab-#{service_key}"

    with :ok <- ensure_network(@network) do
      provision_template(container_name, template)
    end
  end

  def provision_service(_), do: {:error, :unknown_service}

  def available_services do
    Enum.map(@system_templates, fn {key, tmpl} ->
      %{key: key, name: tmpl.name, image: tmpl.image}
    end)
  end

  defp provision_template(container_name, template) do
    Logger.info("Infrastructure: provisioning #{template.name}")

    case Client.get("/containers/#{container_name}/json") do
      {:ok, %{"State" => %{"Running" => true}}} ->
        {:ok, :already_running}

      {:ok, _} ->
        case Client.post("/containers/#{container_name}/start") do
          {:ok, _} ->
            {:ok, :started}

          {:error, _reason} ->
            Logger.warning("Infrastructure: stale container #{container_name}, recreating")
            Client.delete("/containers/#{container_name}?force=true")
            create_system_container(container_name, template)
        end

      {:error, {:not_found, _}} ->
        create_system_container(container_name, template)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_system_container(name, template) do
    Logger.info("Infrastructure: pulling image #{template.image}...")
    _ = Client.post_stream("/images/create?fromImage=#{URI.encode(template.image)}")

    port_bindings =
      template.ports
      |> Enum.reduce(%{}, fn p, acc ->
        Map.put(acc, "#{p["container"]}/tcp", [%{"HostPort" => to_string(p["host"])}])
      end)

    mounts =
      Enum.map(template.volumes, fn v ->
        %{"Type" => v["type"], "Source" => v["source"], "Target" => v["target"]}
      end)

    body = %{
      "Image" => template.image,
      "Env" => Map.get(template, :env, []),
      "Labels" => template.labels,
      "Cmd" => template.command,
      "HostConfig" => %{
        "NetworkMode" => @network,
        "PortBindings" => port_bindings,
        "Mounts" => mounts,
        "RestartPolicy" => %{"Name" => "unless-stopped"}
      }
    }

    with {:ok, %{"Id" => _id}} <- Client.post("/containers/create?name=#{name}", body),
         {:ok, _} <- Client.post("/containers/#{name}/start") do
      Logger.info("Infrastructure: #{template.name} started")
      {:ok, :started}
    else
      {:error, reason} -> {:error, {:create_failed, reason}}
    end
  end

  @doc """
  Connects Traefik to a specific network so it can route traffic to containers on that network.
  Safe to call multiple times — skips if already connected.
  """
  def connect_traefik_to_network(network_name) do
    case Client.get("/containers/homelab-traefik/json") do
      {:ok, %{"Id" => traefik_id, "NetworkSettings" => %{"Networks" => networks}}} ->
        unless Map.has_key?(networks, network_name) do
          Logger.info("Infrastructure: connecting Traefik to network #{network_name}")
          Client.post("/networks/#{network_name}/connect", %{"Container" => traefik_id})
        end

        :ok

      {:error, {:not_found, _}} ->
        :ok

      {:error, reason} ->
        Logger.warning("Infrastructure: failed to inspect Traefik: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Connects Traefik to all `homelab_*_net` deployment networks. Called after Traefik starts
  to ensure it can reach every existing deployment.
  """
  def sync_traefik_networks do
    case Client.get("/networks") do
      {:ok, networks} when is_list(networks) ->
        deployment_nets =
          networks
          |> Enum.filter(fn n -> String.starts_with?(n["Name"] || "", "homelab_") end)
          |> Enum.map(& &1["Name"])

        Enum.each(deployment_nets, &connect_traefik_to_network/1)
        :ok

      _ ->
        :ok
    end
  end

  defp ensure_network(network_name) do
    case Client.get("/networks/#{network_name}") do
      {:ok, _} ->
        :ok

      {:error, {:not_found, _}} ->
        case Client.post("/networks/create", %{"Name" => network_name, "Driver" => "bridge"}) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:network_create_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
