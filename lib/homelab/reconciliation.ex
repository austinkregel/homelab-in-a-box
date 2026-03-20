defmodule Homelab.Reconciliation do
  @moduledoc """
  Pure-function module that compares desired state (from DB) against
  actual state (from orchestrator) and produces a diff of actions.

  This module has no side effects — it takes data in and returns a diff.
  The caller is responsible for executing the actions.
  """

  alias Homelab.Reconciliation.Diff

  @doc """
  Computes the diff between desired deployments and actual running services.

  ## Parameters
    - `desired` - list of deployment records from the database
    - `actual` - list of service status maps from the orchestrator

  ## Returns
    A `%Diff{}` struct containing lists of deployments/services to deploy,
    remove, restart, update, or that are already in sync.
  """
  @spec compute_diff(desired :: [map()], actual :: [map()]) :: Diff.t()
  def compute_diff(desired, actual) do
    actual_by_id = Map.new(actual, &{&1.id, &1})

    desired_external_ids =
      desired
      |> Enum.reject(&is_nil(&1.external_id))
      |> MapSet.new(& &1.external_id)

    {to_deploy, existing} =
      Enum.split_with(desired, fn d ->
        d.status == :pending or is_nil(d.external_id) or
          not Map.has_key?(actual_by_id, d.external_id)
      end)

    {to_update, to_restart, in_sync} =
      Enum.reduce(existing, {[], [], []}, fn d, {upd, rst, sync} ->
        actual_service = Map.get(actual_by_id, d.external_id)

        cond do
          is_nil(actual_service) ->
            {upd, rst, sync}

          actual_service.state == :failed ->
            {upd, [d | rst], sync}

          needs_update?(d, actual_service) ->
            {[d | upd], rst, sync}

          true ->
            {upd, rst, [d | sync]}
        end
      end)

    to_remove =
      Enum.filter(actual, fn a ->
        is_managed?(a) and not MapSet.member?(desired_external_ids, a.id)
      end)

    %Diff{
      to_deploy: to_deploy,
      to_remove: to_remove,
      to_restart: Enum.reverse(to_restart),
      to_update: Enum.reverse(to_update),
      in_sync: Enum.reverse(in_sync)
    }
  end

  defp needs_update?(desired, actual) do
    desired_image =
      get_in(desired, [Access.key(:computed_spec), :image]) ||
        get_in(desired, [Access.key(:computed_spec), "image"])

    desired_image != nil and desired_image != actual.image
  end

  defp is_managed?(service) do
    Map.get(service.labels, "homelab.managed") == "true"
  end
end
