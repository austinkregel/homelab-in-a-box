defmodule Homelab.Catalog.Enrichers.ComposeParser do
  @moduledoc """
  Parses docker-compose YAML files to extract structured deployment metadata
  including ports, volumes, environment variables, and service dependencies.
  """

  @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
  def parse(yaml_content) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, data} ->
        service = pick_primary_service(data)

        if service do
          {:ok, extract_service_metadata(service)}
        else
          {:ok, empty_result()}
        end

      {:error, reason} ->
        {:error, {:yaml_parse_failed, reason}}
    end
  end

  @spec parse_all(String.t()) :: {:ok, [map()]} | {:error, term()}
  def parse_all(yaml_content) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, %{"services" => services}} when is_map(services) ->
        result =
          Enum.map(services, fn {name, service} ->
            metadata = extract_service_metadata(service)
            Map.merge(metadata, %{name: name, image: service["image"] || ""})
          end)

        {:ok, result}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:yaml_parse_failed, reason}}
    end
  end

  defp pick_primary_service(%{"services" => services}) when is_map(services) do
    db_names = ~w(db database postgres postgresql mysql mariadb redis mongo mongodb memcached)

    non_db_services =
      Enum.reject(services, fn {name, _} ->
        String.downcase(name) in db_names
      end)

    case non_db_services do
      [{_name, service} | _] -> service
      [] -> services |> Map.values() |> List.first()
    end
  end

  defp pick_primary_service(_), do: nil

  defp extract_service_metadata(service) do
    %{
      ports: parse_ports(service["ports"]),
      volumes: parse_volumes(service["volumes"]),
      env: parse_environment(service["environment"]),
      depends_on: parse_depends_on(service["depends_on"])
    }
  end

  defp parse_ports(nil), do: []

  defp parse_ports(ports) when is_list(ports) do
    Enum.flat_map(ports, fn
      port when is_binary(port) ->
        parse_port_string(port)

      port when is_map(port) ->
        internal = to_string(port["target"] || port["container_port"])

        [
          %{
            "internal" => internal,
            "external" => to_string(port["published"] || port["host_port"] || port["target"]),
            "description" => nil,
            "optional" => false,
            "role" => Homelab.Catalog.Enrichers.PortRoles.infer(internal)
          }
        ]

      port when is_integer(port) ->
        [
          %{
            "internal" => to_string(port),
            "external" => to_string(port),
            "description" => nil,
            "optional" => false,
            "role" => Homelab.Catalog.Enrichers.PortRoles.infer(to_string(port))
          }
        ]

      _ ->
        []
    end)
  end

  defp parse_ports(_), do: []

  defp parse_port_string(port_str) do
    cleaned = String.replace(port_str, ~r|/\w+$|, "")

    case String.split(cleaned, ":") do
      [external, internal] ->
        internal = String.trim(internal)

        [
          %{
            "internal" => internal,
            "external" => String.trim(external),
            "description" => nil,
            "optional" => false,
            "role" => Homelab.Catalog.Enrichers.PortRoles.infer(internal)
          }
        ]

      [_host_ip, external, internal] ->
        internal = String.trim(internal)

        [
          %{
            "internal" => internal,
            "external" => String.trim(external),
            "description" => nil,
            "optional" => false,
            "role" => Homelab.Catalog.Enrichers.PortRoles.infer(internal)
          }
        ]

      [single] ->
        single = String.trim(single)

        [
          %{
            "internal" => single,
            "external" => single,
            "description" => nil,
            "optional" => false,
            "role" => Homelab.Catalog.Enrichers.PortRoles.infer(single)
          }
        ]

      _ ->
        []
    end
  end

  defp parse_volumes(nil), do: []

  defp parse_volumes(volumes) when is_list(volumes) do
    Enum.flat_map(volumes, fn
      vol when is_binary(vol) ->
        parse_volume_string(vol)

      vol when is_map(vol) ->
        [
          %{
            "path" => vol["target"] || vol["container_path"],
            "description" => nil,
            "optional" => false
          }
        ]

      _ ->
        []
    end)
    |> Enum.reject(fn vol -> is_nil(vol["path"]) end)
  end

  defp parse_volumes(_), do: []

  defp parse_volume_string(vol_str) do
    case String.split(vol_str, ":") do
      [_host, container | _] ->
        [%{"path" => String.trim(container), "description" => nil, "optional" => false}]

      [single] ->
        if String.starts_with?(single, "/") do
          [%{"path" => String.trim(single), "description" => nil, "optional" => false}]
        else
          []
        end

      _ ->
        []
    end
  end

  defp parse_environment(nil), do: []

  defp parse_environment(env) when is_list(env) do
    Enum.flat_map(env, fn
      item when is_binary(item) ->
        case String.split(item, "=", parts: 2) do
          [key, value] -> [%{"key" => String.trim(key), "value" => String.trim(value)}]
          [key] -> [%{"key" => String.trim(key), "value" => ""}]
        end

      _ ->
        []
    end)
  end

  defp parse_environment(env) when is_map(env) do
    Enum.map(env, fn {key, value} ->
      %{"key" => to_string(key), "value" => if(value, do: to_string(value), else: "")}
    end)
  end

  defp parse_environment(_), do: []

  defp parse_depends_on(nil), do: []

  defp parse_depends_on(deps) when is_list(deps) do
    Enum.map(deps, &to_string/1)
  end

  defp parse_depends_on(deps) when is_map(deps) do
    Map.keys(deps) |> Enum.map(&to_string/1)
  end

  defp parse_depends_on(_), do: []

  defp empty_result do
    %{ports: [], volumes: [], env: [], depends_on: []}
  end
end
