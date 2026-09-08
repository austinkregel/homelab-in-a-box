defmodule Homelab.Catalog.Enrichers.RepoScannerStub do
  @moduledoc """
  Stands in for `Homelab.Catalog.Enrichers.RepoScanner` in tests, so enrichment does not
  fetch raw.githubusercontent.com for whatever `project_url` an entry carries.

  The companion to `ImageInspectorStub`, staged the same way and for the same reason:
  enrichment runs both halves from a `Task` on mount. The scanner's own tests point the
  real module at Bypass through its `:base_url` config, and are unaffected by this.
  """

  def scan(project_url) when is_binary(project_url) do
    Application.get_env(:homelab, :repo_scanner_result, {:error, :stubbed})
  end

  def scan(_), do: {:error, :no_project_url}
end
