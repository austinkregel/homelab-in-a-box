defmodule Homelab.Storage do
  @moduledoc """
  Where the bytes actually live.

  Storage in this app is described in three places that never met: `df` knows the host's
  physical disks, the daemon knows its named volumes and how much they weigh, and the
  deployments table knows which container mounts what. Each on its own answers a question
  nobody asks. Together they answer the ones people do — *what is filling this disk*,
  *is anything still using this volume*, *where does this app's data actually sit*.

  This module is the join. It reads all three and returns them cross-referenced, so a
  volume carries its consumers and a bind carries the disk it lands on.

  ## The consumer index

  A deployment's volume row does not always name its source: a blank `source` means
  `SpecBuilder` derives the name at spec-build time. Matching a live volume back to the
  deployment that mounts it therefore has to derive the same name the same way, which is
  why `SpecBuilder.volume_name/3` is public rather than copied. Get this wrong and the
  page reports a volume as unreferenced — which is exactly the volume someone then
  deletes.

  ## Reads are best-effort, and say so

  The daemon can be down, `df` can be unavailable in a stripped container, and
  `/system/df` can time out on a large host. Each source returns `{:ok, _}` or
  `{:error, _}` independently and the page renders whatever came back, because a
  volume list is still worth showing when the disk gauge is not.
  """

  import Ecto.Query, only: [from: 2]

  alias Homelab.Deployments

  alias Homelab.Deployments.{
    Access,
    AdoptionPolicy,
    Netns,
    PermanentHome,
    SpecBuilder,
    VolumeSpec
  }

  alias Homelab.Docker.Client
  alias Homelab.Repo
  alias Homelab.Settings
  alias Homelab.System.{DockerDisk, Metrics}

  @roots_key "storage_mount_roots"
  @roots_category "infrastructure"

  @type consumer :: %{
          deployment_id: binary(),
          name: String.t(),
          tenant: String.t(),
          container_path: String.t(),
          read_only: boolean(),
          status: atom()
        }

  # ---------------------------------------------------------------------------
  # Inventory
  # ---------------------------------------------------------------------------

  @doc """
  Everything the storage page renders, gathered in one pass.

  The consumer index is built once and shared by the volume and bind lists — it walks
  every deployment, and doing that twice to answer two halves of the same question is
  the kind of thing that makes a page feel slow for no reason.
  """
  def inventory do
    consumers = consumer_index()
    usage = docker_usage()
    roots = mount_roots()
    disks = host_disks()

    %{
      disks: disks,
      usage: usage,
      volumes: volumes(consumers, usage),
      binds: binds(consumers, roots, disks),
      roots: roots
    }
  end

  @doc "Host filesystems from `df`, largest-used first is NOT applied — mount order is stable."
  def host_disks, do: Metrics.disks()

  @doc """
  Docker's own accounting from `GET /system/df`. Slow on a big host (30s timeout), so the
  page loads it asynchronously rather than blocking the first render.
  """
  def docker_usage do
    case DockerDisk.collect() do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Volumes
  # ---------------------------------------------------------------------------

  @doc """
  Named volumes on the daemon, each annotated with its size, whether we own it, and the
  deployments that mount it.

  `in_use` comes from Docker's own RefCount (a *running* container holds it), while
  `consumers` comes from our records (a deployment that is stopped still owns its data).
  They disagree constantly and both are true — a volume with consumers and no refs is
  a stopped app, not garbage.
  """
  def volumes(consumers \\ nil, usage \\ nil) do
    consumers = consumers || consumer_index()
    usage = usage || docker_usage()
    sizes = usage_by_name(usage)

    case orchestrator().list_volumes() do
      {:ok, vols} ->
        vols
        |> Enum.map(&annotate_volume(&1, consumers, sizes))
        |> Enum.sort_by(&{&1.size == nil, -(&1.size || 0), &1.name})
        |> then(&{:ok, &1})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp annotate_volume(vol, consumers, sizes) do
    labels = vol[:labels] || vol["labels"] || %{}
    name = vol[:name] || vol["name"]
    usage = Map.get(sizes, name)

    %{
      name: name,
      driver: vol[:driver] || vol["driver"],
      labels: labels,
      size: usage && usage.size,
      in_use: usage && usage.in_use,
      managed: Map.get(labels, "homelab.managed") == "true",
      adopted: Map.get(labels, "homelab.adopted") == "true",
      consumers: Map.get(consumers, {"volume", name}, [])
    }
  end

  defp usage_by_name({:ok, %{volumes: %{items: items}}}),
    do: Map.new(items, &{&1.name, %{size: &1.size, in_use: &1.in_use}})

  defp usage_by_name(_), do: %{}

  # ---------------------------------------------------------------------------
  # Binds (host folder mounts)
  # ---------------------------------------------------------------------------

  @doc """
  Every host path mounted into a deployment, one entry per distinct source path.

  Each carries the disk it lands on — resolved by longest-prefix match against the `df`
  mount points, the same way the kernel picks a filesystem — so "this app's data is on
  the NAS" is legible without cross-referencing two tables by eye.
  """
  def binds(consumers \\ nil, roots \\ nil, disks \\ nil) do
    consumers = consumers || consumer_index()
    roots = roots || mount_roots()
    disks = disks || host_disks()

    consumers
    |> Enum.filter(fn {{type, _source}, _} -> type == "bind" end)
    |> Enum.map(fn {{_type, source}, mounts} ->
      %{
        source: source,
        consumers: mounts,
        disk: disk_for(source, disks),
        root: root_for(source, roots)
      }
    end)
    |> Enum.sort_by(& &1.source)
  end

  # Longest matching mount point wins, which is how the kernel resolves it: `/mnt/tank`
  # and `/` both "match" a path under the former, and only the longer one is the disk
  # the bytes are actually on.
  defp disk_for(source, disks) do
    disks
    |> Enum.filter(&under?(source, &1.mount))
    |> Enum.max_by(&String.length(&1.mount), fn -> nil end)
  end

  defp root_for(source, roots) do
    roots
    |> Enum.filter(&under?(source, &1.path))
    |> Enum.max_by(&String.length(&1.path), fn -> nil end)
  end

  defp under?(path, prefix) when is_binary(path) and is_binary(prefix),
    do: path == prefix or String.starts_with?(path, String.trim_trailing(prefix, "/") <> "/")

  defp under?(_path, _prefix), do: false

  # ---------------------------------------------------------------------------
  # Consumer index
  # ---------------------------------------------------------------------------

  @doc """
  `%{{type, source} => [consumer]}` across every deployment.

  A blank `source` is resolved through `SpecBuilder.volume_name/3` — the same derivation
  the spec builder performs — so a deployment that never named its volume still shows up
  against the volume it really mounts.
  """
  def consumer_index do
    Deployments.list_deployments()
    |> Enum.flat_map(&deployment_mounts/1)
    |> Enum.group_by(& &1.key, & &1.consumer)
  end

  defp deployment_mounts(deployment) do
    deployment
    |> Access.effective_volumes()
    |> Enum.map(&VolumeSpec.normalize/1)
    |> Enum.reject(&(&1["container_path"] in [nil, ""]))
    |> Enum.map(fn vol ->
      %{
        key: resolved_key(vol, deployment),
        consumer: %{
          deployment_id: deployment.id,
          # A deployment has no name of its own — the catalog entry it came from is what
          # the rest of the UI shows, so showing anything else here would name the same
          # thing two ways on two pages.
          name: deployment.app_template && deployment.app_template.name,
          tenant: deployment.tenant && deployment.tenant.slug,
          container_path: vol["container_path"],
          read_only: vol["read_only"],
          status: deployment.status
        }
      }
    end)
  end

  defp resolved_key(%{"source" => source, "type" => type}, _deployment)
       when is_binary(source) and source != "",
       do: {type, source}

  # No source: SpecBuilder derives a tenant-scoped name and mounts THAT. Anything else
  # here would report the derived volume as unreferenced.
  defp resolved_key(%{"container_path" => path}, deployment) do
    {"volume",
     SpecBuilder.volume_name(
       deployment.tenant && deployment.tenant.slug,
       deployment.app_template && deployment.app_template.slug,
       path
     )}
  end

  # ---------------------------------------------------------------------------
  # Mount roots
  # ---------------------------------------------------------------------------

  @doc """
  Named host paths the operator has registered, plus the two built-in roots.

  The built-ins (`adoption_root`, `managed_root`) are listed alongside the custom ones
  and marked `builtin: true`. They are not editable here — Settings → Infrastructure owns
  them, and having two forms write the same key is how they end up disagreeing.
  """
  def mount_roots do
    builtin = [
      %{name: "Adoption root", path: AdoptionPolicy.adoption_root(), builtin: true},
      %{name: "Managed root", path: PermanentHome.managed_root(), builtin: true}
    ]

    builtin ++ custom_roots()
  end

  @doc "Only the operator-registered roots, in insertion order."
  def custom_roots do
    case Settings.get(@roots_key) do
      value when is_binary(value) and value != "" ->
        case Jason.decode(value) do
          {:ok, list} when is_list(list) ->
            Enum.flat_map(list, fn
              %{"name" => name, "path" => path} ->
                [%{name: name, path: path, builtin: false}]

              _ ->
                []
            end)

          _ ->
            []
        end

      _ ->
        []
    end
  end

  @doc """
  Registers a named host path. Refuses a relative path: every consumer of a root joins
  onto it to build a bind source, and a relative one yields a bind Docker reads as a
  named volume — the silent-empty-mount failure `VolumeSpec` exists to prevent.
  """
  def put_mount_root(name, path) do
    name = String.trim(name || "")
    path = path |> to_string() |> String.trim() |> String.trim_trailing("/")

    cond do
      name == "" ->
        {:error, "a root needs a name"}

      not String.starts_with?(path, "/") ->
        {:error, "a mount root must be an absolute host path (got #{inspect(path)})"}

      Enum.any?(custom_roots(), &(&1.name == name)) ->
        {:error, "a root named #{inspect(name)} already exists"}

      true ->
        save_roots(custom_roots() ++ [%{name: name, path: path, builtin: false}])
    end
  end

  @doc "Forgets a registered root. Metadata only — nothing on disk is touched."
  def delete_mount_root(name) do
    save_roots(Enum.reject(custom_roots(), &(&1.name == name)))
  end

  defp save_roots(roots) do
    payload = Enum.map(roots, &%{"name" => &1.name, "path" => &1.path})

    case Settings.set(@roots_key, Jason.encode!(payload), category: @roots_category) do
      {:ok, _} -> {:ok, roots}
      {:error, _} -> {:error, "could not save the mount roots"}
    end
  end

  # ---------------------------------------------------------------------------
  # Creating a volume
  # ---------------------------------------------------------------------------

  @doc """
  Creates a Docker named volume.

  Two shapes, and the difference matters more than the form suggests:

    * `%{"name" => n}` — an ordinary `local` volume. Docker picks where the bytes go
      (somewhere under its data root) and only Docker can find them again.

    * `%{"name" => n, "device" => "/mnt/..."}` — a `device`-bind volume, the same shape
      `PermanentHome` builds. The bytes live in a directory you named, so they can be
      backed up, moved, or read with `ls` — while still being a named volume specs can
      reference. Docker will NOT create that directory, and mounting fails if it is
      absent, so this refuses a device path that does not exist rather than handing back
      a volume that breaks at deploy time.

  Volumes created here are labelled `homelab.managed=true`: the reconciler's orphan sweep
  and the adoption scan both key off that label, and an unlabelled volume created by this
  app would read to both of them as somebody else's.
  """
  def create_volume(attrs) do
    name = attrs |> Map.get("name") |> to_string() |> String.trim()
    device = attrs |> Map.get("device") |> to_string() |> String.trim()

    cond do
      name == "" ->
        {:error, "a volume needs a name"}

      not Regex.match?(~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/, name) ->
        {:error, "a volume name may only contain letters, numbers, and _ . -"}

      device != "" and not String.starts_with?(device, "/") ->
        {:error, "a backing folder must be an absolute host path (got #{inspect(device)})"}

      device != "" and not File.dir?(device) ->
        {:error,
         "#{device} does not exist or is not readable from here — Docker will not create " <>
           "a device-bind volume's folder, and mounting it would fail at deploy time"}

      true ->
        post_volume(volume_payload(name, device))
    end
  end

  defp volume_payload(name, "") do
    %{"Name" => name, "Driver" => "local", "Labels" => %{"homelab.managed" => "true"}}
  end

  defp volume_payload(name, device) do
    %{
      "Name" => name,
      "Driver" => "local",
      "DriverOpts" => %{"type" => "none", "o" => "bind", "device" => device},
      "Labels" => %{"homelab.managed" => "true"}
    }
  end

  defp post_volume(payload) do
    case Client.post("/volumes/create", payload) do
      {:ok, _} -> {:ok, payload["Name"]}
      {:error, reason} -> {:error, "Docker refused the volume: #{inspect(reason)}"}
    end
  end

  @doc """
  Deletes a named volume.

  Refused while any deployment still lists it, stopped or not: Docker's own RefCount only
  counts *running* containers, so deleting on that signal alone destroys the data of every
  app that happens to be down. Pass `force: true` to override once the operator has seen
  the consumer list.
  """
  def delete_volume(name, opts \\ []) do
    consumers = Map.get(consumer_index(), {"volume", name}, [])

    if consumers != [] and not Keyword.get(opts, :force, false) do
      {:error,
       "#{name} is still mounted by #{Enum.map_join(consumers, ", ", & &1.name)} — remove the " <>
         "mount from those deployments first, or confirm the delete"}
    else
      case Client.delete("/volumes/#{name}") do
        {:ok, _} -> :ok
        {:error, {:not_found, _}} -> :ok
        {:error, reason} -> {:error, "Docker refused the delete: #{inspect(reason)}"}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Attaching a mount to a deployment
  # ---------------------------------------------------------------------------

  @doc """
  Adds one volume row to an existing deployment and recreates it.

  Writes `volumes_override`, which means the deployment stops inheriting its template's
  volumes from this point on — so the existing effective list is carried over rather than
  replaced. Appending to `nil` would otherwise silently drop every volume the template
  declared, which for a database is the whole of its data.

  A container cannot gain a mount without being recreated, so this reconverges. A member
  of a network-namespace group goes round as a group: recreating one member mints a new
  container id the others are pinned to.
  """
  def attach_mount(deployment_id, row) do
    with {:ok, deployment} <- fetch_deployment(deployment_id),
         existing = Access.effective_volumes(deployment),
         volumes = VolumeSpec.parse(existing ++ [row]),
         {:ok, updated} <- update_volumes(deployment, volumes),
         {:ok, _} <- reconverge(updated) do
      {:ok, Deployments.get_deployment!(updated.id)}
    end
  end

  defp fetch_deployment(id) do
    case Deployments.get_deployment(id) do
      {:ok, deployment} -> {:ok, deployment}
      {:error, :not_found} -> {:error, "that deployment no longer exists"}
    end
  end

  defp update_volumes(deployment, volumes) do
    case Deployments.update_deployment(deployment, %{volumes_override: volumes}) do
      {:ok, updated} -> {:ok, updated}
      {:error, %Ecto.Changeset{} = cs} -> {:error, HomelabWeb.ChangesetErrors.to_sentence(cs)}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp reconverge(deployment) do
    stack? = not is_nil(deployment.network_parent_id) or Netns.donor?(deployment)

    result =
      if stack?,
        do: Deployments.redeploy_netns_stack(deployment),
        else: Deployments.recreate_deployment(deployment)

    case result do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, "Mount saved, but recreate failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Deployments a mount can be attached to, newest first, with tenant preloaded.

  Deliberately every deployment rather than only the running ones: adding a volume to a
  stopped app is how you fix the reason it is stopped.
  """
  def attachable_deployments do
    Repo.all(
      from(d in Deployments.Deployment,
        order_by: [desc: d.inserted_at],
        preload: [:tenant, :app_template]
      )
    )
  end

  defp orchestrator, do: Homelab.Config.orchestrator()
end
