defmodule Homelab.Catalog.Enrichers.DockerfileParser do
  @moduledoc """
  Regex-based parser for Dockerfile directives.
  Extracts EXPOSE, VOLUME, and ENV declarations.
  """

  @spec parse(String.t()) :: {:ok, map()}
  def parse(content) do
    {:ok,
     %{
       ports: parse_expose(content),
       volumes: parse_volume(content),
       env: parse_env(content)
     }}
  end

  defp parse_expose(content) do
    ~r/^EXPOSE\s+(.+)$/mi
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_, args] ->
      args
      |> String.split(~r/\s+/, trim: true)
      |> Enum.map(fn port_str ->
        port_num = port_str |> String.replace(~r|/\w+$|, "") |> String.trim()

        %{
          "internal" => port_num,
          "external" => port_num,
          "description" => nil,
          "optional" => false,
          "role" => Homelab.Catalog.Enrichers.PortRoles.infer(port_num)
        }
      end)
    end)
  end

  defp parse_volume(content) do
    ~r/^VOLUME\s+(.+)$/mi
    |> Regex.scan(content)
    |> Enum.flat_map(fn [_, args] ->
      args = String.trim(args)

      paths =
        if String.starts_with?(args, "[") do
          args
          |> String.trim_leading("[")
          |> String.trim_trailing("]")
          |> String.split(",")
          |> Enum.map(fn p ->
            p |> String.trim() |> String.trim("\"") |> String.trim("'")
          end)
        else
          String.split(args, ~r/\s+/, trim: true)
        end

      Enum.map(paths, fn path ->
        %{
          "path" => path,
          "description" => nil,
          "optional" => false
        }
      end)
    end)
  end

  defp parse_env(content) do
    key_value_pairs =
      ~r/^ENV\s+(\S+?)=(.*)$/mi
      |> Regex.scan(content)
      |> Enum.map(fn [_, key, value] ->
        %{"key" => String.trim(key), "value" => String.trim(value) |> unquote_value()}
      end)

    space_separated =
      ~r/^ENV\s+(\S+)\s+(.+)$/mi
      |> Regex.scan(content)
      |> Enum.reject(fn [_, key, _] -> String.contains?(key, "=") end)
      |> Enum.map(fn [_, key, value] ->
        %{"key" => String.trim(key), "value" => String.trim(value) |> unquote_value()}
      end)

    seen = MapSet.new(key_value_pairs, fn %{"key" => k} -> k end)

    unique_space =
      Enum.reject(space_separated, fn %{"key" => k} -> MapSet.member?(seen, k) end)

    (key_value_pairs ++ unique_space)
    |> Enum.reject(fn %{"key" => key} -> system_env?(key) end)
  end

  defp unquote_value(val) do
    val
    |> String.trim("\"")
    |> String.trim("'")
  end

  @system_env_prefixes ~w(PATH HOME HOSTNAME LANG LC_ TERM SHLVL _ GOPATH JAVA_HOME)
  defp system_env?(key) do
    Enum.any?(@system_env_prefixes, fn prefix -> String.starts_with?(key, prefix) end)
  end
end
