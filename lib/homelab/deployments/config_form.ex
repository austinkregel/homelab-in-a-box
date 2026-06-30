defmodule Homelab.Deployments.ConfigForm do
  @moduledoc """
  Shared parsing for deployment config forms, so the deploy wizard and the
  post-deploy Settings editor produce identically-shaped port maps.
  """

  alias Homelab.Catalog.Enrichers.PortRoles

  @doc """
  Normalizes indexed port form params (`%{"0" => %{...}, "1" => %{...}}`) into an
  ordered list of string-keyed port maps. Booleans arrive as the strings
  `"true"`/`"false"`. Blank-container-port rows are dropped.
  """
  def parse_ports(nil), do: []

  def parse_ports(ports_map) when is_map(ports_map) do
    ports_map
    |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, port} -> normalize_port(port) end)
    |> Enum.reject(fn p -> p["internal"] in [nil, ""] end)
  end

  defp normalize_port(port) do
    role = port["role"]
    role = if role in [nil, "", "other"], do: PortRoles.infer(port["internal"]), else: role

    %{
      "internal" => port["internal"],
      "external" => port["external"],
      "description" => port["description"] || "",
      "optional" => port["optional"] == "true",
      "role" => role,
      "published" => port["published"] == "true"
    }
  end
end
