defmodule Homelab.Infrastructure do
  @moduledoc """
  Manages system-level infrastructure services (reverse proxy, DNS, auth providers).
  These are deployed as regular containers but tagged as system services.
  """

  require Logger
  alias Homelab.Docker.Client

  @system_label "homelab.system"
  # The plane's own backbone (system services + the Traefik<->deployment routing
  # fabric). Namespaced `homelab-iab-` so it never collides with an existing
  # stack's `homelab-internal`. Keep in sync with the orchestrators' routing net.
  @network "homelab-iab-internal"

  @system_templates %{
    "traefik" => %{
      name: "Traefik",
      image: "traefik:v3.6",
      # Only the public web entrypoints are bound to the host. Traefik's API and
      # dashboard stay on :8080 *inside* the container (reached over the Docker
      # network as homelab-traefik:8080 for metrics/API) and are deliberately NOT
      # host-exposed — that insecure dashboard must never be reachable externally,
      # and host-binding it also collided with app deployments' own ports.
      ports: [
        %{"host" => 80, "container" => 80},
        %{"host" => 443, "container" => 443}
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
        # ACME challenge flags (DNS-01 + provider) are injected at provision time
        # by `ensure_traefik/0` from the operator-supplied DNS API token.
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

  @doc "The shared internal Docker network all system services sit on."
  def internal_network, do: @network

  @doc "The label marking a container as a homelab system service."
  def system_label, do: @system_label

  @doc "Idempotently ensures the shared internal network exists."
  def ensure_internal_network, do: ensure_network(@network)

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
    with {:ok, template} <- build_traefik_template(),
         :ok <- ensure_network(@network),
         result when result in [{:ok, :already_running}, {:ok, :started}] <-
           ensure_traefik_current(template) do
      sync_traefik_networks()
      result
    end
  end

  @dns_token_env "TRAEFIK_DNS_API_TOKEN"
  @dns_provider "cloudflare"

  # Builds the Traefik template with a wildcard DNS-01 ACME resolver. The DNS
  # provider API token is supplied by the operator via the #{@dns_token_env}
  # environment variable and injected as container env — never HTTP-01, and
  # never provisioned without a token.
  defp build_traefik_template do
    case System.get_env(@dns_token_env) do
      token when is_binary(token) and token != "" ->
        # Let's Encrypt rejects a malformed contact, so this must be a real email.
        # Prefer the operator-set `acme_email`; otherwise default to admin@<domain>
        # (NOT the bare domain, which isn't an email and fails account registration).
        acme_email =
          Homelab.Settings.get("acme_email") ||
            "admin@#{Homelab.Settings.get("base_domain", "homelab.local")}"

        acme_cmd = [
          "--certificatesresolvers.letsencrypt.acme.email=#{acme_email}",
          "--certificatesresolvers.letsencrypt.acme.dnschallenge=true",
          "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=#{@dns_provider}",
          "--certificatesresolvers.letsencrypt.acme.dnschallenge.resolvers=1.1.1.1:53"
        ]

        template =
          @system_templates
          |> Map.fetch!("traefik")
          |> Map.update!(:command, &(&1 ++ acme_cmd))
          |> Map.put(:env, ["CF_DNS_API_TOKEN=#{token}"])

        {:ok, template}

      _ ->
        Logger.error(
          "Infrastructure: #{@dns_token_env} is not set — cannot provision Traefik with wildcard DNS-01 TLS"
        )

        {:error, :dns_token_missing}
    end
  end

  # Like provision_template/2, but force-recreates Traefik when its running
  # command/env drifts from the desired ACME config — otherwise the idempotent
  # "already running" short-circuit would never apply a challenge-type change.
  defp ensure_traefik_current(template) do
    container = "homelab-traefik"

    case Client.get("/containers/#{container}/json") do
      {:ok, %{"State" => %{"Running" => true}, "Config" => config}} ->
        if traefik_config_drifted?(config, template) do
          Logger.info("Infrastructure: Traefik ACME config drift detected, recreating")
          Client.delete("/containers/#{container}?force=true")
          create_system_container(container, template)
        else
          {:ok, :already_running}
        end

      {:ok, _} ->
        Client.delete("/containers/#{container}?force=true")
        create_system_container(container, template)

      {:error, {:not_found, _}} ->
        create_system_container(container, template)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp traefik_config_drifted?(config, template) do
    actual_cmd = config["Cmd"] || []
    actual_env = config["Env"] || []
    desired_cmd = template.command
    desired_env = Map.get(template, :env, [])

    not (subset?(desired_cmd, actual_cmd) and subset?(desired_env, actual_env))
  end

  defp subset?(desired, actual) do
    desired_set = MapSet.new(desired)
    actual_set = MapSet.new(actual)
    MapSet.subset?(desired_set, actual_set)
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
  Disconnects Traefik from a network, severing the external route to whatever is on it.
  Safe to call multiple times — skips if not connected. Never touches workload containers.
  """
  def disconnect_traefik_from_network(network_name) do
    case Client.get("/containers/homelab-traefik/json") do
      {:ok, %{"Id" => traefik_id, "NetworkSettings" => %{"Networks" => networks}}} ->
        if Map.has_key?(networks, network_name) do
          Logger.info("Infrastructure: disconnecting Traefik from network #{network_name}")

          Client.post("/networks/#{network_name}/disconnect", %{
            "Container" => traefik_id,
            "Force" => true
          })
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
  Returns the list of network names Traefik is currently connected to.
  """
  def traefik_networks do
    case Client.get("/containers/homelab-traefik/json") do
      {:ok, %{"NetworkSettings" => %{"Networks" => networks}}} when is_map(networks) ->
        Map.keys(networks)

      _ ->
        []
    end
  end

  @doc """
  Connects Traefik only to the networks of currently-running, ingress-published
  deployments. Called after Traefik starts. Fail-closed: it deliberately does NOT
  reconnect Traefik to unready, failed, or orphaned deployment networks — that is
  the reconciler's job to enforce continuously.
  """
  def sync_traefik_networks do
    Homelab.Deployments.list_published_running()
    |> Enum.each(fn deployment ->
      network =
        Homelab.Deployments.SpecBuilder.deployment_network(
          deployment.tenant,
          deployment.app_template
        )

      connect_traefik_to_network(network)
    end)

    :ok
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
