defmodule Homelab.Deployments.ConfigForm do
  @moduledoc """
  Shared parsing for deployment config forms, so the deploy wizard and the
  post-deploy Settings editor produce identically-shaped port maps.
  """

  alias Homelab.Catalog.Enrichers.PortRoles
  alias Homelab.Deployments.Access

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
    # Infer only when the form carried NO role. "other" is an explicit answer, and
    # re-inferring it silently promoted demoted ports back to "web" on every save.
    role = port["role"]
    role = if role in [nil, ""], do: PortRoles.infer(port["internal"]), else: role

    %{
      "internal" => port["internal"],
      "external" => port["external"],
      "description" => port["description"] || "",
      "optional" => port["optional"] == "true",
      "role" => role,
      # Normalized through Access so a form that posts no protocol field at all — an
      # older cached page, or a submit path that hasn't grown the input yet — yields
      # "tcp" rather than nil, and the stored map always answers the question.
      "protocol" => Access.port_protocol(port),
      # The interface a host port is published on. nil = all of them (Docker's default).
      # Carried so an adopted `127.0.0.1:` binding is not silently widened to 0.0.0.0 the
      # first time the operator saves anything on the Settings page.
      "host_ip" => blank_to_nil(port["host_ip"]),
      "published" => port["published"] == "true"
    }
  end

  defp blank_to_nil(host_ip) when host_ip in [nil, "", "0.0.0.0"], do: nil
  defp blank_to_nil(host_ip) when is_binary(host_ip), do: String.trim(host_ip)
  defp blank_to_nil(_host_ip), do: nil
end
