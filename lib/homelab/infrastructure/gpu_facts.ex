defmodule Homelab.Infrastructure.GpuFacts do
  @moduledoc """
  What the daemon (or the cluster) can ACTUALLY do with a GPU, read from
  `GET /info` and `GET /nodes` — as opposed to what a deployment's config claims
  it wants.

  This module exists because of one specific failure: under Swarm, a GPU request
  the cluster cannot satisfy **does not error**. Reserve a generic resource no
  node advertises and the task sits `pending` forever, with an empty error field
  and a service that looks deployed. Get the resource kind right but leave the
  vendor runtime off `default-runtime` and the task *starts* — with no GPU inside,
  which surfaces hours later as an inference error in someone else's logs.

  Neither is discoverable from the deployment's own config: both are facts about
  the host's `daemon.json`, which is not writable through any API. So we read
  them and refuse the deploy, rather than letting the operator watch a task hang.
  """

  alias Homelab.Docker.Client
  alias Homelab.Deployments.GpuSpec

  @doc """
  The generic-resource kinds the swarm's nodes actually advertise, e.g.
  `["NVIDIA-GPU"]`. `[]` means no node offers a GPU — which is also the answer on
  a daemon with no GPU configured, and is exactly what makes a request unschedulable.
  """
  def advertised_kinds do
    case Client.get("/nodes") do
      {:ok, nodes} when is_list(nodes) ->
        kinds =
          nodes
          |> Enum.flat_map(&node_generic_resources/1)
          |> Enum.map(&resource_kind/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        {:ok, kinds}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The runtimes the daemon knows about and which one it uses by default, e.g.
  `%{runtimes: ["runc", "nvidia"], default_runtime: "nvidia"}`.

  `default_runtime` is the load-bearing one under Swarm: a service cannot ask for a
  runtime, so the vendor hook only runs if it is the node's DEFAULT.
  """
  def runtimes do
    case Client.get("/info") do
      {:ok, info} when is_map(info) -> {:ok, extract_runtimes(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Pure projection of a `/info` body, so the mapping is testable without a daemon."
  def extract_runtimes(info) when is_map(info) do
    %{
      runtimes: info |> Map.get("Runtimes", %{}) |> Map.keys() |> Enum.sort(),
      default_runtime: Map.get(info, "DefaultRuntime")
    }
  end

  def extract_runtimes(_info), do: %{runtimes: [], default_runtime: nil}

  @doc """
  Checks a GPU request against the SWARM cluster before we deploy it.

  Returns `:ok`, or `{:error, message}` naming the exact `daemon.json` change that
  would make it schedulable. A probe failure (daemon unreachable) is NOT fatal: we
  do not block a deploy because we could not ask. The task would then hang, which
  is the status quo — refusing on a failed probe would turn a transient socket blip
  into an outage.
  """
  def preflight_swarm(nil), do: :ok

  def preflight_swarm(%{kind: kind, vendor: vendor}) do
    case advertised_kinds() do
      {:ok, []} ->
        {:error, no_gpu_nodes_message(kind, vendor)}

      {:ok, kinds} ->
        if kind in kinds,
          do: :ok,
          else: {:error, kind_mismatch_message(kind, kinds)}

      # Could not ask. Do not block on a question we failed to pose.
      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Checks a GPU request against a single-daemon (non-Swarm) Engine.

  NVIDIA needs the container toolkit registered as a runtime; without it,
  `DeviceRequests` fails with a driver error that reads like a bug in us.

  AMD is deliberately NOT preflighted: it passes `/dev/kfd` + `/dev/dri` directly,
  and if those do not exist the daemon says so plainly. There is nothing we could
  add by guessing at host device nodes we cannot see from inside a container.
  """
  def preflight_engine(nil), do: :ok

  def preflight_engine(%{vendor: "nvidia"}) do
    case runtimes() do
      {:ok, %{runtimes: runtimes}} ->
        if "nvidia" in runtimes,
          do: :ok,
          else: {:error, no_nvidia_runtime_message()}

      {:error, _reason} ->
        :ok
    end
  end

  def preflight_engine(%{vendor: _other}), do: :ok

  @doc """
  Everything the Infrastructure tab needs to tell an operator whether this box can
  run a GPU workload, and what is missing if it cannot.
  """
  def capabilities do
    runtime_facts =
      case runtimes() do
        {:ok, facts} -> facts
        {:error, _} -> %{runtimes: [], default_runtime: nil}
      end

    kinds =
      case advertised_kinds() do
        {:ok, kinds} -> kinds
        {:error, _} -> []
      end

    vendor_runtimes = Enum.filter(runtime_facts.runtimes, &(&1 in GpuSpec.vendors()))

    %{
      runtimes: runtime_facts.runtimes,
      default_runtime: runtime_facts.default_runtime,
      vendor_runtimes: vendor_runtimes,
      advertised_kinds: kinds,
      # Under Swarm the hook only runs if it is the DEFAULT runtime -- a service has
      # no way to ask for one. A vendor runtime that is installed but not default is
      # the subtlest of the failures here: the task schedules and starts, with no GPU.
      default_runtime_is_vendor: runtime_facts.default_runtime in GpuSpec.vendors()
    }
  end

  # --- messages -------------------------------------------------------------
  #
  # These are the actual remediation, not a restatement of the error. The operator
  # cannot fix any of this from our UI -- it all lives in daemon.json on the host --
  # so the message has to carry the fix.

  defp no_gpu_nodes_message(kind, vendor) do
    """
    No node in this swarm advertises a GPU, so this service would sit pending forever \
    rather than fail. Swarm cannot pass devices (--device is rejected in swarm mode); \
    a GPU is only reachable as a generic resource the node declares.

    On the GPU node, add to /etc/docker/daemon.json:

        {
          "default-runtime": "#{vendor}",
          "node-generic-resources": ["#{kind}=<gpu-uuid>"]
        }

    then restart the daemon. `default-runtime` is what actually puts the device in \
    the container; the generic resource only decides which node the task lands on. \
    Both are required.\
    """
  end

  defp kind_mismatch_message(kind, advertised) do
    """
    This service asks for the resource "#{kind}", but the nodes in this swarm \
    advertise: #{Enum.map_join(advertised, ", ", &~s("#{&1}"))}. Swarm matches the \
    kind byte-for-byte and does not warn on a miss -- the task would sit pending \
    forever.

    Either set the GPU resource kind to one of the above, or change \
    "node-generic-resources" in the node's /etc/docker/daemon.json to advertise \
    "#{kind}".\
    """
  end

  defp no_nvidia_runtime_message do
    """
    This daemon has no "nvidia" runtime registered, so a GPU device request would be \
    refused by the driver. Install the NVIDIA Container Toolkit on the host and \
    register it (`nvidia-ctk runtime configure --runtime=docker`), then restart the \
    daemon.\
    """
  end

  defp node_generic_resources(node) when is_map(node) do
    node
    |> Map.get("Description", %{})
    |> Kernel.||(%{})
    |> Map.get("Resources", %{})
    |> Kernel.||(%{})
    |> Map.get("GenericResources", [])
    |> List.wrap()
  end

  defp node_generic_resources(_node), do: []

  # A node advertises either a NAMED resource (a specific GPU, by uuid) or a DISCRETE
  # one (a count). Both carry the Kind, which is the only part we match on.
  defp resource_kind(%{"NamedResourceSpec" => %{"Kind" => kind}}), do: kind
  defp resource_kind(%{"DiscreteResourceSpec" => %{"Kind" => kind}}), do: kind
  defp resource_kind(_resource), do: nil
end
