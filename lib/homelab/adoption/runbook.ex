defmodule Homelab.Adoption.Runbook do
  @moduledoc """
  Generates per-app markdown runbooks for manual migration (§B3).
  The platform never executes these commands.
  """

  alias Homelab.Adoption.AdoptedApp

  def generate(%AdoptedApp{} = app, opts \\ []) do
    tenant = Keyword.get(opts, :tenant_slug, app.tenant_slug || "default")
    pool = Keyword.get(opts, :pool, "tank")
    target = "imports/#{tenant}/#{app.slug}"

    md = """
    # Migration runbook: #{app.slug}

    **Classification:** #{app.classification}  
    **Source:** `#{app.source_path}`  
    **Size:** #{format_size(app.size_bytes)}  

    The control plane does **not** run these commands. Execute manually when ready.

    ## Phase 1 — Warm copy (app keeps running)

    ```bash
    sudo rsync -aHAX --info=progress2 \\
      #{app.source_path}/ \\
      /#{pool}/#{target}/
    ```

    ## Phase 2 — Cutover (brief downtime)

    ```bash
    # Stop the original container
    docker stop <container-name>

    # Final sync
    sudo rsync -aHAX --delete \\
      #{app.source_path}/ \\
      /#{pool}/#{target}/

    # Point the deployment at the new dataset mount, then restart via homelab-in-a-box
    ```

    ## Verify (after ZFS is available)

    ```bash
    zfs snapshot #{pool}/#{target}@post-migration
    ```

    When finished, mark this app as imported in the Adoption UI.
    """

    {:ok, String.trim(md)}
  end

  defp format_size(nil), do: "unknown"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GiB"
end
