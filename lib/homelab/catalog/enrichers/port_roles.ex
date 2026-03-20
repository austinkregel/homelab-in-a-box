defmodule Homelab.Catalog.Enrichers.PortRoles do
  @moduledoc """
  Suggests a semantic role for a port number based on common conventions.

  This is used during enrichment to provide sensible defaults.
  The user can override the role in the deploy UI before deploying.

  Recognized roles:
  - `"web"` — HTTP/HTTPS frontends
  - `"ssh"` — SSH access
  - `"database"` — database servers
  - `"mail"` — email services
  - `"dns"` — DNS resolvers
  - `"ftp"` — file transfer
  - `"other"` — anything unrecognized
  """

  @web_ports ~w(80 443 3000 3001 4000 5000 8000 8080 8443 8888 9000 9090 9443)

  @doc """
  Returns a list of all available role options for UI dropdowns.
  """
  def available_roles do
    [
      {"Web", "web"},
      {"SSH", "ssh"},
      {"Database", "database"},
      {"Mail", "mail"},
      {"DNS", "dns"},
      {"FTP", "ftp"},
      {"Other", "other"}
    ]
  end

  @doc """
  Infers a semantic role for a port based on its number.
  Returns a string like `"web"`, `"database"`, `"ssh"`, or `"other"`.
  """
  def infer(port_str) do
    port = to_string(port_str)

    cond do
      port in @web_ports -> "web"
      port in ~w(22 2222) -> "ssh"
      port in ~w(3306 5432 5433 27017 6379 11211) -> "database"
      port in ~w(25 465 587 993 143 110) -> "mail"
      port in ~w(53 853) -> "dns"
      port in ~w(21 20) -> "ftp"
      true -> "other"
    end
  end
end
