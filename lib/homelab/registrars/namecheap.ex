defmodule Homelab.Registrars.Namecheap do
  @moduledoc """
  Namecheap registrar integration.

  Lists domains owned by the configured Namecheap account. The Namecheap API
  returns XML and requires `ApiUser`, `ApiKey`, `UserName`, and `ClientIp`
  global parameters on every request.

  Domain IDs from Namecheap are stored as strings in `provider_zone_id`.
  """

  @behaviour Homelab.Behaviours.RegistrarProvider

  require Record

  Record.defrecordp(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))

  Record.defrecordp(
    :xmlAttribute,
    Record.extract(:xmlAttribute, from_lib: "xmerl/include/xmerl.hrl")
  )

  Record.defrecordp(:xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  @production_url "https://api.namecheap.com/xml.response"
  @sandbox_url "https://api.sandbox.namecheap.com/xml.response"
  @page_size 100

  @impl true
  def driver_id, do: "namecheap"

  @impl true
  def display_name, do: "Namecheap"

  @impl true
  def description, do: "Sync domains from your Namecheap account"

  @impl true
  def list_domains do
    case credentials() do
      {:error, _} = err -> err
      {:ok, creds} -> fetch_all_domains(creds, 1, [])
    end
  end

  @impl true
  def get_nameservers(domain) do
    case credentials() do
      {:error, _} = err ->
        err

      {:ok, creds} ->
        {sld, tld} = split_domain(domain)

        params =
          global_params(creds, "namecheap.domains.dns.getList")
          |> Map.merge(%{"SLD" => sld, "TLD" => tld})

        case api_request(creds, params) do
          {:ok, doc} ->
            nameservers =
              :xmerl_xpath.string(~c"//Nameserver", doc)
              |> Enum.map(&text_content/1)
              |> Enum.reject(&(&1 == ""))

            {:ok, nameservers}

          {:error, _} = err ->
            err
        end
    end
  end

  defp fetch_all_domains(creds, page, acc) do
    params =
      global_params(creds, "namecheap.domains.getList")
      |> Map.merge(%{"Page" => to_string(page), "PageSize" => to_string(@page_size)})

    case api_request(creds, params) do
      {:ok, doc} ->
        domains =
          :xmerl_xpath.string(~c"//Domain", doc)
          |> Enum.map(fn elem ->
            %{
              name: xml_attr(elem, :Name),
              provider_zone_id: xml_attr(elem, :ID),
              status: domain_status(elem),
              name_servers: []
            }
          end)

        all = acc ++ domains

        total_items = paging_value(doc, "TotalItems")
        current_page = paging_value(doc, "CurrentPage")
        page_size_val = paging_value(doc, "PageSize")

        has_more =
          total_items != nil and current_page != nil and page_size_val != nil and
            page_size_val > 0 and current_page * page_size_val < total_items

        if has_more do
          fetch_all_domains(creds, page + 1, all)
        else
          {:ok, all}
        end

      {:error, _} = err ->
        err
    end
  end

  defp api_request(creds, params) do
    url = base_url(creds)

    case Req.get(url, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        parse_xml(body)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc false
  def parse_xml(xml_string) when is_binary(xml_string) do
    try do
      {doc, _rest} = :xmerl_scan.string(String.to_charlist(xml_string), quiet: true)

      case :xmerl_xpath.string(~c"//ApiResponse/@Status", doc) do
        [attr | _] ->
          status = xmlAttribute(attr, :value) |> to_string()

          if status == "OK" do
            {:ok, doc}
          else
            errors =
              :xmerl_xpath.string(~c"//Error", doc)
              |> Enum.map(&text_content/1)

            {:error, {:api_errors, errors}}
          end

        [] ->
          {:ok, doc}
      end
    rescue
      e -> {:error, {:xml_parse_error, Exception.message(e)}}
    catch
      :exit, reason -> {:error, {:xml_parse_error, inspect(reason)}}
    end
  end

  defp xml_attr(element, attr_name) do
    attrs = xmlElement(element, :attributes)

    case Enum.find(attrs, fn a -> xmlAttribute(a, :name) == attr_name end) do
      nil -> ""
      attr -> xmlAttribute(attr, :value) |> to_string()
    end
  end

  defp text_content(element) do
    xmlElement(element, :content)
    |> Enum.filter(fn node ->
      Record.is_record(node, :xmlText)
    end)
    |> Enum.map(fn text_node -> xmlText(text_node, :value) |> to_string() end)
    |> Enum.join()
    |> String.trim()
  end

  defp paging_value(doc, tag_name) do
    case :xmerl_xpath.string(~c"//Paging/#{String.to_charlist(tag_name)}", doc) do
      [elem | _] ->
        case Integer.parse(text_content(elem)) do
          {n, _} -> n
          :error -> nil
        end

      [] ->
        nil
    end
  end

  defp domain_status(elem) do
    expired = xml_attr(elem, :IsExpired)
    if expired == "true", do: "expired", else: "active"
  end

  defp split_domain(domain) do
    parts = String.split(domain, ".")

    case parts do
      [sld, tld] -> {sld, tld}
      [sld | rest] -> {sld, Enum.join(rest, ".")}
      _ -> {domain, "com"}
    end
  end

  defp global_params(creds, command) do
    %{
      "ApiUser" => creds.api_user,
      "ApiKey" => creds.api_key,
      "UserName" => creds.username,
      "ClientIp" => creds.client_ip,
      "Command" => command
    }
  end

  defp base_url(creds) do
    if creds.sandbox, do: @sandbox_url, else: @production_url
  end

  defp credentials do
    api_user = Homelab.Settings.get("namecheap_api_user")
    api_key = Homelab.Settings.get("namecheap_api_key")

    cond do
      is_nil(api_user) or api_user == "" ->
        {:error, :not_configured}

      is_nil(api_key) or api_key == "" ->
        {:error, :not_configured}

      true ->
        {:ok,
         %{
           api_user: api_user,
           api_key: api_key,
           username: Homelab.Settings.get("namecheap_username", api_user),
           client_ip: Homelab.Settings.get("namecheap_client_ip", "127.0.0.1"),
           sandbox: Homelab.Settings.get("namecheap_use_sandbox", "false") == "true"
         }}
    end
  end
end
