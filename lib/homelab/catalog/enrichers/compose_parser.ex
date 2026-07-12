defmodule Homelab.Catalog.Enrichers.ComposeParser do
  @moduledoc """
  Parses docker-compose YAML files to extract structured deployment metadata
  including ports, volumes, environment variables, and service dependencies.
  """

  @doc """
  Options accepted by `parse/2` and `parse_all/2`:

    * `:project_dir` — the absolute host directory the compose file lives in. Compose
      resolves a relative bind source (`./data`) against it, and derives the default
      project name (which prefixes named volumes) from its basename. Without it, a
      relative source is carried through verbatim and will fail validation rather than
      resolve to the wrong place.
  """
  @spec parse(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def parse(yaml_content, opts \\ []) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, data} ->
        service = pick_primary_service(data)

        if service do
          {:ok, extract_service_metadata(service, opts)}
        else
          {:ok, empty_result()}
        end

      {:error, reason} ->
        {:error, {:yaml_parse_failed, reason}}
    end
  end

  @spec parse_all(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def parse_all(yaml_content, opts \\ []) do
    case YamlElixir.read_from_string(yaml_content) do
      {:ok, %{"services" => services}} when is_map(services) ->
        result =
          Enum.map(services, fn {name, service} ->
            metadata = extract_service_metadata(service, opts)
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

  defp extract_service_metadata(service, opts) do
    %{
      ports: parse_ports(service["ports"]),
      volumes: parse_volumes(service["volumes"], opts),
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

  defp parse_volumes(nil, _opts), do: []

  defp parse_volumes(volumes, opts) when is_list(volumes) do
    Enum.flat_map(volumes, fn
      vol when is_binary(vol) ->
        parse_volume_string(vol, opts)

      # Long form: %{"type" => "bind", "source" => "./data", "target" => "/var/lib/x"}
      vol when is_map(vol) ->
        [
          volume(
            vol["target"] || vol["container_path"],
            vol["source"],
            vol["type"],
            opts
          )
        ]

      _ ->
        []
    end)
    |> Enum.reject(fn vol -> is_nil(vol["path"]) end)
  end

  defp parse_volumes(_volumes, _opts), do: []

  # `HOST:CONTAINER[:ro]`. The HOST side is the whole point of a compose import -- it is
  # where the data already lives. Dropping it (as this used to) turns every folder mount
  # into a fresh, empty named volume.
  defp parse_volume_string(vol_str, opts) do
    case String.split(vol_str, ":") do
      [host, container | _mode] ->
        [volume(container, host, nil, opts)]

      # A bare container path is an ANONYMOUS volume: Docker owns it, no host side.
      [single] ->
        single = String.trim(single)

        if String.starts_with?(single, "/"),
          do: [volume(single, nil, "volume", opts)],
          else: []

      _ ->
        []
    end
  end

  defp volume(container_path, source, type, opts) do
    source = source && String.trim(source)
    type = type || infer_type(source)

    %{
      "path" => container_path && String.trim(container_path),
      "type" => type,
      "source" => resolve_source(source, type, opts),
      "description" => nil,
      "optional" => false
    }
  end

  # Compose's own rule: a source that looks like a PATH is a bind, anything else names a
  # volume declared in the top-level `volumes:` block.
  defp infer_type(nil), do: "volume"

  defp infer_type(source) do
    if String.starts_with?(source, ["/", "./", "../", "~/"]) or source in [".", ".."],
      do: "bind",
      else: "volume"
  end

  defp resolve_source(nil, _type, _opts), do: nil

  defp resolve_source(source, "bind", opts) do
    project_dir = Keyword.get(opts, :project_dir)

    cond do
      String.starts_with?(source, "/") ->
        source

      # `~` is the HOST user's home. We are running inside a container, so expanding it
      # here would resolve against the wrong home -- leave it for the operator to fix,
      # where validation will point at it.
      String.starts_with?(source, "~") ->
        source

      is_binary(project_dir) and String.starts_with?(project_dir, "/") ->
        Path.expand(source, project_dir)

      # No project dir: carry the relative path through verbatim. It fails validation and
      # the operator is asked for the absolute path -- which is right. Silently resolving
      # it against some other directory would mount a real folder that holds nothing.
      true ->
        source
    end
  end

  # A named volume created by `docker compose` is prefixed with the project name, whose
  # default is the basename of the project directory. Referencing the bare name would
  # point at a DIFFERENT (and empty) volume than the one the old stack has been writing
  # to, so resolve it the same way compose does.
  defp resolve_source(source, "volume", opts) do
    case Keyword.get(opts, :project_dir) do
      dir when is_binary(dir) and dir != "" ->
        case project_name(dir) do
          "" -> source
          project -> "#{project}_#{source}"
        end

      _ ->
        source
    end
  end

  defp resolve_source(source, _type, _opts), do: source

  defp project_name(project_dir) do
    project_dir
    |> Path.basename()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "")
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
