defmodule Homelab.Deployments.AdoptionPlanner do
  @moduledoc """
  Turns `AdoptionDiscovery` captures into a review model and a migrate-to-managed-home
  release plan. This is the wiring between discovery and the saga.

  `review/0` groups each in-scope container's mounts by tier for an operator to
  confirm. `build_plan/1` takes the selected reviews and produces, per service,
  the proposed managed `AppTemplate` attrs and the ordered saga `step_specs` split
  into `:phase1` (copy while the stack stays up) and `:phase2` (the cutover).

  Everything here is **pure** — no daemon writes, no DB writes, no enqueue. The
  caller (Settings "Import") previews the plan; execution happens in a later step.
  """

  alias Homelab.Deployments.{AdoptionDiscovery, PermanentHome}

  @doc """
  Discovers in-scope containers and returns a per-service review model, or an error.
  """
  def review do
    case AdoptionDiscovery.discover_in_scope() do
      {:ok, captures} -> {:ok, Enum.map(captures, &to_review/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds a dry-run plan from selected review entries (the maps `review/0` returns).
  Returns `%{services: [...], phase1: [step_spec], phase2: [step_spec]}`.

  ## Strategy

    * `:migrate` (default) — copy each preserved mount into a plane-owned permanent home
      and cut the managed container over to that. The original's data is never touched,
      so a rollback is a true restore. Costs a second copy of the data, and the time to
      make it.

    * `:in_place` — mount the ORIGINAL directory (or named volume) into the managed
      container, exactly as the old container had it. Nothing is copied: adoption is
      near-instant and needs no extra disk. The trade is that there is no second copy to
      fall back to, so `BackupVerify` is the only net — a rollback restores the old
      *container*, not the bytes it may have written. This is the strategy for a stack
      that is already folder mounts, or data too large to duplicate.
  """
  def build_plan(selected_reviews, opts \\ []) when is_list(selected_reviews) do
    strategy = Keyword.get(opts, :strategy, :migrate)
    services = Enum.map(selected_reviews, &plan_service(&1, strategy))

    %{
      # Each service carries its own ordered phase1/phase2 so the apply path can
      # plan one release per service; the top-level flat lists stay for the
      # preview UI (and existing aggregate tests).
      services:
        Enum.map(services, fn s ->
          Map.merge(s.service, %{phase1: s.phase1, phase2: s.phase2})
        end),
      phase1: Enum.flat_map(services, & &1.phase1),
      phase2: Enum.flat_map(services, & &1.phase2)
    }
  end

  # --- internals ------------------------------------------------------------

  defp to_review(capture) do
    mounts = capture.mounts || []

    %{
      name: capture.name,
      image: capture.image,
      user: capture.user,
      restart_policy: capture.restart_policy,
      container_id: capture.id || capture.name,
      preserve: Enum.filter(mounts, &(&1.tier == :preserve)),
      rebuildable: Enum.filter(mounts, &(&1.tier == :rebuildable)),
      out_of_scope: Enum.filter(mounts, &(&1.tier == :out_of_scope))
    }
  end

  defp plan_service(review, strategy) do
    name = review.name
    container = review.container_id
    targets = Enum.map(review.preserve, &target(name, &1, strategy))

    template_attrs = %{
      slug: "adopted-#{slug(name)}",
      name: name,
      version: "adopted",
      image: review.image,
      user: review.user,
      source: "adopted",
      source_id: name,
      description: "Adopted from existing container #{name}",
      # Host exposure so the cutover container can bind the original's host ports
      # (spec_builder only binds host ports in :host mode).
      exposure_mode: :host,
      volumes: Enum.map(review.preserve, &volume_entry(name, &1, strategy))
    }

    {phase1, phase2} = phases(strategy, name, container, review, targets)

    %{
      service: %{name: name, template_attrs: template_attrs, targets: targets},
      phase1: phase1,
      phase2: phase2
    }
  end

  # :migrate copies the bytes first (phase 1), while the old stack stays up, then cuts
  # over onto the copy.
  defp phases(:migrate, name, container, review, targets) do
    phase1 = [
      %{type: :backup_verify, resource_handle: %{"targets" => targets}},
      %{type: :quiesce_old, resource_handle: %{"container" => container}},
      %{type: :migrate_volume, resource_handle: %{"targets" => targets}},
      %{
        type: :resume_old,
        resource_handle: %{"container" => container, "restart_policy" => review.restart_policy}
      }
    ]

    phase2 = [
      credentials_step(name, container, review),
      %{type: :adopt_volume, resource_handle: %{"targets" => targets}},
      cutover_step(name, container, review, targets),
      %{type: :verify_integrity, resource_handle: %{"service" => name}}
    ]

    {phase1, phase2}
  end

  # :in_place moves no bytes, so there is nothing to copy (no :migrate_volume), nothing
  # to quiesce for a copy (no :quiesce_old / :resume_old — the cutover does its own stop),
  # and no permanent home to register (no :adopt_volume). What remains is proving a backup
  # exists and swapping the container onto the data it already sits on.
  defp phases(:in_place, name, container, review, targets) do
    phase1 = [
      %{type: :backup_verify, resource_handle: %{"targets" => targets}}
    ]

    phase2 = [
      credentials_step(name, container, review),
      cutover_step(name, container, review, targets),
      %{type: :verify_integrity, resource_handle: %{"service" => name}}
    ]

    {phase1, phase2}
  end

  defp credentials_step(name, container, review) do
    %{
      type: :adopt_credentials,
      resource_handle: %{"container" => container, "image" => review.image, "service" => name}
    }
  end

  defp cutover_step(name, container, review, targets) do
    %{
      type: :adopt_container,
      resource_handle: %{
        "container" => container,
        "restart_policy" => review.restart_policy,
        "targets" => targets,
        "service" => name
      }
    }
  end

  # A saga target for a preserve mount. `path`/`source` are the real filesystem
  # location (the volume mountpoint, or the bind source) so the backup and copy
  # engines read the actual bytes — never a recomputed volume name.
  #
  # `strategy` rides along so the cutover knows whether its delta re-sync has anywhere to
  # sync TO. An in-place target has no permanent home, and "re-syncing" it would copy the
  # directory onto itself.
  defp target(service, mount, strategy) do
    %{
      "name" => service,
      "path" => mount.mountpoint || mount.source,
      "source" => mount.mountpoint || mount.source,
      "container_path" => mount.target,
      "tier" => to_string(mount.tier),
      "strategy" => to_string(strategy)
    }
  end

  # :migrate — a plane-owned device-bind volume name, passed through spec_builder verbatim.
  defp volume_entry(service, mount, :migrate) do
    %{
      "container_path" => mount.target,
      "source" => PermanentHome.volume_name(service, mount.target),
      "type" => "volume"
    }
  end

  # :in_place — reference exactly what the original container referenced: the host
  # directory for a bind, or the existing named volume for a volume. Either way the
  # managed container mounts the same bytes, and nothing is copied.
  defp volume_entry(_service, mount, :in_place) do
    %{
      "container_path" => mount.target,
      "source" => mount.source,
      "type" => to_string(mount.type)
    }
  end

  defp slug(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
