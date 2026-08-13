defmodule Homelab.ContainerId do
  @moduledoc """
  Recognizes a Docker container ID, used to tell whether the app is running
  inside a container by inspecting its `HOSTNAME`.

  Docker sets a container's hostname to the short (12) or full (64) hex ID
  unless overridden. `Homelab.Bootstrap` and `Homelab.Infrastructure` both
  need this check; the pattern lives here so it can't drift between them.
  """

  # 12-char short form through 64-char full form, all lowercase hex.
  @pattern ~r/^[a-f0-9]{12,64}$/

  @doc """
  True if `hostname` looks like a Docker container ID. Non-binaries (e.g. a
  missing `HOSTNAME`) are not container IDs.
  """
  @spec hostname?(term()) :: boolean()
  def hostname?(hostname) when is_binary(hostname), do: String.match?(hostname, @pattern)
  def hostname?(_), do: false
end
