defmodule Homelab.Gateways.Traefik do
  @moduledoc """
  Traefik reverse proxy / gateway implementation.

  Manages Traefik dynamic configuration via file provider or Docker labels.
  Handles route registration, TLS certificate provisioning (via Let's Encrypt),
  and exposure mode enforcement.

  Configuration:
    config :homelab, Homelab.Gateways.Traefik,
      config_dir: "/etc/traefik/dynamic",
      acme_email: "admin@example.com",
      api_url: "http://traefik:8080"
  """

  @behaviour Homelab.Behaviours.Gateway

  @impl true
  def driver_id, do: "traefik"

  @impl true
  def display_name, do: "Traefik"

  @impl true
  def description, do: "Cloud-native reverse proxy with automatic HTTPS and Docker integration"

  @impl true
  def register_route(domain, upstream, opts \\ []) do
    exposure = Keyword.get(opts, :exposure, :sso_protected)
    config = route_config(domain, upstream, exposure)
    config_path = route_file_path(domain)

    case write_config(config_path, config) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def remove_route(domain) do
    config_path = route_file_path(domain)

    case File.rm(config_path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_routes do
    config_dir = config_dir()

    case File.ls(config_dir) do
      {:ok, files} ->
        routes =
          files
          |> Enum.filter(&String.ends_with?(&1, ".yml"))
          |> Enum.map(fn file ->
            domain = file |> String.trim_trailing(".yml")
            %{domain: domain, config_file: Path.join(config_dir, file)}
          end)

        {:ok, routes}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def provision_tls(domain) do
    config = config()
    api_url = Keyword.get(config, :api_url, "http://traefik:8080")
    acme_email = Keyword.get(config, :acme_email, "admin@homelab.local")

    # Traefik handles TLS automatically via ACME when a router has a TLS
    # configuration. We ensure the route config includes the cert resolver.
    # For non-ACME setups, we can trigger a certificate check.
    case Req.get("#{api_url}/api/http/routers/#{sanitize_router_name(domain)}", retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        tls_info = body["tls"] || %{}

        {:ok,
         %{
           domain: domain,
           cert_resolver: tls_info["certResolver"] || "letsencrypt",
           acme_email: acme_email,
           status: :active
         }}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :route_not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @impl true
  def check_tls_expiry(domain) do
    config = config()
    api_url = Keyword.get(config, :api_url, "http://traefik:8080")

    case Req.get("#{api_url}/api/http/routers/#{sanitize_router_name(domain)}", retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case get_in(body, ["tls", "notAfter"]) do
          nil ->
            # Traefik doesn't always expose expiry via API, estimate 90 days from now
            {:ok, DateTime.add(DateTime.utc_now(), 90 * 24 * 3600, :second)}

          date_str ->
            case DateTime.from_iso8601(date_str) do
              {:ok, dt, _} -> {:ok, dt}
              _ -> {:error, :invalid_date}
            end
        end

      {:ok, %Req.Response{status: 404}} ->
        {:error, :route_not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  # --- Config generation ---

  defp route_config(domain, upstream, exposure) do
    router_name = sanitize_router_name(domain)
    service_name = "svc-#{router_name}"

    middlewares = build_middlewares(router_name, exposure)

    config = %{
      "http" => %{
        "routers" => %{
          router_name => %{
            "rule" => "Host(`#{domain}`)",
            "service" => service_name,
            "tls" => %{
              "certResolver" => "letsencrypt"
            },
            "middlewares" => Map.keys(middlewares)
          }
        },
        "services" => %{
          service_name => %{
            "loadBalancer" => %{
              "servers" => [%{"url" => upstream}]
            }
          }
        },
        "middlewares" => middlewares
      }
    }

    encode_yaml(config)
  end

  defp build_middlewares(router_name, :sso_protected) do
    %{
      "#{router_name}-auth" => %{
        "forwardAuth" => %{
          "address" => "http://authentik-proxy:9000/outpost.goauthentik.io/auth/nginx",
          "trustForwardHeader" => true,
          "authResponseHeaders" => [
            "X-authentik-username",
            "X-authentik-groups",
            "X-authentik-email"
          ]
        }
      }
    }
  end

  defp build_middlewares(_router_name, :public) do
    %{}
  end

  defp build_middlewares(router_name, :private) do
    %{
      "#{router_name}-ipwhitelist" => %{
        "ipAllowList" => %{
          "sourceRange" => ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
        }
      }
    }
  end

  defp build_middlewares(_router_name, _) do
    %{}
  end

  # --- Helpers ---

  defp route_file_path(domain) do
    Path.join(config_dir(), "#{sanitize_router_name(domain)}.yml")
  end

  defp config_dir do
    config = config()
    Keyword.get(config, :config_dir, "/etc/traefik/dynamic")
  end

  defp write_config(path, content) do
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, content) do
      :ok
    end
  end

  defp config do
    Application.get_env(:homelab, __MODULE__, [])
  end

  defp sanitize_router_name(domain) do
    domain
    |> String.replace(".", "-")
    |> String.replace(~r/[^a-z0-9-]/i, "")
    |> String.downcase()
  end

  # Simple YAML-like encoding for Traefik config files.
  # For production, consider using a proper YAML library.
  defp encode_yaml(map) do
    Jason.encode!(map, pretty: true)
    |> then(fn json ->
      # Traefik supports JSON dynamic config files too
      json
    end)
  end
end
