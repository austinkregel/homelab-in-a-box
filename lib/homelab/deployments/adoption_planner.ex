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
  """
  def build_plan(selected_reviews) when is_list(selected_reviews) do
    services = Enum.map(selected_reviews, &plan_service/1)

    %{
      services: Enum.map(services, & &1.service),
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

  defp plan_service(review) do
    name = review.name
    container = review.container_id
    targets = Enum.map(review.preserve, &target(name, &1))

    template_attrs = %{
      slug: "adopted-#{slug(name)}",
      name: name,
      version: "adopted",
      image: review.image,
      user: review.user,
      source: "adopted",
      source_id: name,
      volumes: Enum.map(review.preserve, &managed_volume(name, &1))
    }

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
      %{
        type: :adopt_credentials,
        resource_handle: %{"container" => container, "service" => name}
      },
      %{type: :adopt_volume, resource_handle: %{"targets" => targets}},
      %{type: :adopt_container, resource_handle: %{"service" => name}},
      %{type: :verify_integrity, resource_handle: %{"service" => name}}
    ]

    %{
      service: %{name: name, template_attrs: template_attrs, targets: targets},
      phase1: phase1,
      phase2: phase2
    }
  end

  # A saga target for a preserve mount. `path`/`source` are the real filesystem
  # location (the volume mountpoint, or the bind source) so the backup and copy
  # engines read the actual bytes — never a recomputed volume name.
  defp target(service, mount) do
    %{
      "name" => service,
      "path" => mount.mountpoint || mount.source,
      "source" => mount.mountpoint || mount.source,
      "container_path" => mount.target,
      "tier" => to_string(mount.tier)
    }
  end

  # The managed container's volume entry: a plane-owned device-bind volume name,
  # passed through spec_builder verbatim (see build_volumes/2).
  defp managed_volume(service, mount) do
    %{
      "container_path" => mount.target,
      "source" => PermanentHome.volume_name(service, mount.target),
      "type" => "volume"
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
