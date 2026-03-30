defmodule Homelab.Registrars.Cloudflare do
  @moduledoc """
  Cloudflare registrar integration.

  Lists zones accessible to the configured API token. Each zone maps
  to a DNS zone in the local database. Cloudflare zone IDs are stored
  as `provider_zone_id` for use by the Cloudflare DNS provider.
  """

  @behaviour Homelab.Behaviours.RegistrarProvider

  defp base_url do
    Application.get_env(:homelab, __MODULE__, [])[:base_url] ||
      "https://api.cloudflare.com/client/v4"
  end

  @impl true
  def driver_id, do: "cloudflare"

  @impl true
  def display_name, do: "Cloudflare"

  @impl true
  def description, do: "Sync domains from Cloudflare-managed zones"

  @impl true
  def list_domains do
    case api_token() do
      nil ->
        {:error, :not_configured}

      token ->
        fetch_all_zones(token, 1, [])
    end
  end

  @impl true
  def get_nameservers(domain) do
    case api_token() do
      nil ->
        {:error, :not_configured}

      token ->
        case Req.get("#{base_url()}/zones",
               headers: auth_headers(token),
               params: [name: domain, per_page: 1]
             ) do
          {:ok, %Req.Response{status: 200, body: %{"result" => [zone | _]}}} ->
            {:ok, zone["name_servers"] || []}

          {:ok, %Req.Response{status: 200, body: %{"result" => []}}} ->
            {:error, :zone_not_found}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:api_error, status, body}}

          {:error, reason} ->
            {:error, {:connection_error, reason}}
        end
    end
  end

  defp fetch_all_zones(token, page, acc) do
    case Req.get("#{base_url()}/zones",
           headers: auth_headers(token),
           params: [page: page, per_page: 50, status: "active"]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"result" => zones, "result_info" => info}}} ->
        mapped =
          Enum.map(zones, fn z ->
            %{
              name: z["name"],
              provider_zone_id: z["id"],
              status: z["status"],
              name_servers: z["name_servers"] || []
            }
          end)

        all = acc ++ mapped
        total_pages = info["total_pages"] || 1

        if page < total_pages do
          fetch_all_zones(token, page + 1, all)
        else
          {:ok, all}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp api_token do
    Homelab.Settings.get("cloudflare_api_token")
  end

  defp auth_headers(token) do
    [{"authorization", "Bearer #{token}"}]
  end
end
