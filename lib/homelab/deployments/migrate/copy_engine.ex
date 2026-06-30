defmodule Homelab.Deployments.Migrate.CopyEngine do
  @moduledoc """
  Behaviour for copying an adopted data dir to its permanent home AND proving the
  copy is identical to the original.

  Copy + verify are one operation because, when the plane runs containerized, the
  verification has to happen wherever both paths are readable — possibly inside a
  helper container, not in the plane's process. An engine returns a proof map on
  success (`%{"files", "bytes", "digest", "verified" => true}`) or an error.

  Implementations:

    * `Migrate.LocalCopyEngine` — in-process `File.cp_r` + checksum compare. For
      when the plane can read both paths directly (native plane, or dev/test).
    * a container-based engine (next) — runs `cp -a` + checksum inside a helper
      container that has the source and the managed root bind-mounted, so it
      preserves ownership and sidesteps path translation on a containerized plane.
  """

  @callback migrate(source :: String.t(), dest :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
