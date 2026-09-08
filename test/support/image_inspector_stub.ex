defmodule Homelab.Catalog.Enrichers.ImageInspectorStub do
  @moduledoc """
  Stands in for `Homelab.Catalog.Enrichers.ImageInspector` in tests, so mounting the
  catalog or the deploy wizard does not open a real connection to registry-1.docker.io
  or ghcr.io.

  Both LiveViews kick enrichment off from a `Task` on mount, for whatever image the
  entry happens to name. The catalog's fixtures name plausible-looking images
  (`testapp:latest`), so without this every such mount reaches the internet: slow when
  it times out, and noisy in the log either way.

  The seam sits at `Homelab.Catalog.MetadataEnricher`, the caller, rather than inside
  the inspector — `ImageInspectorTest` still drives the real module against Bypass.

  The default answer is "no metadata", which is what a page-mounting test wants: the
  entry renders with exactly the fields its fixture declared. Tests that want a
  specific result stage it in the application env, and must therefore be `async: false`
  — the inspector runs in a task, which does not inherit the caller's process
  dictionary.
  """

  def inspect(full_ref) when is_binary(full_ref) do
    Application.get_env(:homelab, :image_inspector_result, {:error, :stubbed})
  end

  @doc "The shape a successful inspection returns, for tests that stage one."
  def metadata(fields \\ %{}) do
    Map.merge(%{ports: [], volumes: [], env: [], labels: %{}}, fields)
  end
end
