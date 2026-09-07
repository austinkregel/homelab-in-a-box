defmodule Homelab.Deployments.ReleaseFacts do
  @moduledoc """
  The named booleans a step's `skip?/2` reads about the deployment it targets.

  Every fact delegates to the predicate that already owns the question, so a condition
  and the handler it gates cannot drift apart. Built once per step evaluation by
  `ReleaseRunner` and handed to handlers as `ctx.facts`.
  """

  alias Homelab.Deployments
  alias Homelab.Deployments.Access
  alias Homelab.Deployments.Datastore
  alias Homelab.Deployments.Deployment
  alias Homelab.Deployments.Netns
  alias Homelab.Deployments.SpecBuilder
  alias Homelab.Repo

  defstruct own_domain?: false,
            routed?: false,
            carries_child_routes?: false,
            ingress_published?: false,
            attachable?: false,
            proxy_mode?: false,
            host_network?: false,
            netns_child?: false,
            netns_donor?: false,
            netns_donor_kind?: false,
            declares_healthcheck?: false,
            datastore?: false

  @type t :: %__MODULE__{}

  @doc """
  Facts about the deployment a step acts on: `resource_handle["deployment_id"]` when it
  names one, otherwise the release's own deployment.
  """
  def for_step(step, ctx) do
    step
    |> target(ctx)
    |> build()
  end

  @doc "Facts about one deployment. Everything is false when there is no deployment."
  def build(nil), do: %__MODULE__{}

  def build(%Deployment{} = deployment) do
    # Children preloaded once: `routed?/1` and `carries_child_routes?/1` both read them,
    # and `Netns.children/1` queries per call otherwise.
    deployment =
      deployment
      |> Deployments.with_associations()
      |> Repo.preload(network_children: [:app_template, :tenant])

    %__MODULE__{
      own_domain?: Deployments.own_domain?(deployment),
      routed?: Deployments.routed?(deployment),
      carries_child_routes?: Deployments.carries_child_routes?(deployment),
      ingress_published?: Deployments.ingress_published?(deployment),
      attachable?: Deployments.attachable?(deployment),
      proxy_mode?: Access.proxy_mode?(deployment),
      host_network?: Access.host_network_mode?(deployment),
      netns_child?: Netns.child?(deployment),
      netns_donor?: Netns.donor?(deployment),
      netns_donor_kind?: donor_kind?(deployment),
      declares_healthcheck?:
        SpecBuilder.declares_healthcheck?(Access.effective_health_check(deployment)),
      datastore?: datastore?(deployment)
    }
  end

  @doc "Reads one fact by name. Raises on a name no fact answers to."
  def fetch!(%__MODULE__{} = facts, name), do: Map.fetch!(facts, name)

  # A target that no longer exists yields no facts rather than raising: the step's own
  # handler is where a missing deployment is a failure worth reporting.
  defp target(step, ctx) do
    case Map.get(step.resource_handle || %{}, "deployment_id") do
      nil ->
        Map.get(ctx, :deployment)

      id ->
        case Deployments.get_deployment(id) do
          {:ok, deployment} -> deployment
          {:error, :not_found} -> nil
        end
    end
  end

  defp donor_kind?(%Deployment{app_template: %{netns_donor_kind: kind}}), do: not is_nil(kind)
  defp donor_kind?(_deployment), do: false

  # An engine `Datastore.Grants` can actually drive; anything else is left alone.
  defp datastore?(%Deployment{app_template: %{image: image}}) when is_binary(image),
    do: match?({:ok, _engine}, Datastore.Grants.engine_for_image(image))

  defp datastore?(_deployment), do: false
end
