defmodule Homelab.Reconciliation.DiffTest do
  @moduledoc """
  Branch-coverage tests for `Homelab.Reconciliation.compute_diff/2` and the
  `Homelab.Reconciliation.Diff` struct, focused on cases the existing
  `Homelab.ReconciliationTest` does not exercise: struct defaults, ordering
  guarantees, the `desired_external_ids` reject-nil branch, status/external_id
  combinations driving the deploy split, and removal-protection logic.
  """
  use ExUnit.Case, async: true

  alias Homelab.Reconciliation
  alias Homelab.Reconciliation.Diff

  # -- helpers -------------------------------------------------------------

  defp desired(id, opts) do
    %{
      id: id,
      external_id: Keyword.get(opts, :external_id),
      status: Keyword.get(opts, :status, :running),
      computed_spec: Keyword.get(opts, :computed_spec, %{image: "app:1.0"})
    }
  end

  defp service(id, opts \\ []) do
    %{
      id: id,
      name: Keyword.get(opts, :name, "svc"),
      state: Keyword.get(opts, :state, :running),
      replicas: Keyword.get(opts, :replicas, 1),
      image: Keyword.get(opts, :image, "app:1.0"),
      labels: Keyword.get(opts, :labels, %{"homelab.managed" => "true"})
    }
  end

  # -- Diff struct ---------------------------------------------------------

  describe "Diff struct" do
    test "defaults all categories to empty lists" do
      diff = %Diff{}
      assert diff.to_deploy == []
      assert diff.to_remove == []
      assert diff.to_restart == []
      assert diff.to_update == []
      assert diff.in_sync == []
    end

    test "compute_diff/2 always returns a %Diff{}" do
      assert %Diff{} = Reconciliation.compute_diff([], [])
    end
  end

  # -- deploy split branches ----------------------------------------------

  describe "to_deploy split branches" do
    test "pending status with an existing actual service still deploys" do
      # status == :pending short-circuits even when the service exists
      desired = [desired(1, external_id: "svc_1", status: :pending)]
      actual = [service("svc_1")]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.map(diff.to_deploy, & &1.id) == [1]
      assert diff.in_sync == []
      assert diff.to_update == []
    end

    test "nil external_id with a non-pending status still deploys" do
      desired = [desired(1, external_id: nil, status: :running)]

      diff = Reconciliation.compute_diff(desired, [])
      assert Enum.map(diff.to_deploy, & &1.id) == [1]
    end

    test "external_id present but absent from actual deploys" do
      desired = [desired(1, external_id: "ghost", status: :running)]
      actual = [service("other")]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.map(diff.to_deploy, & &1.id) == [1]
    end

    test "preserves desired order across multiple deploys" do
      desired = [
        desired(1, status: :pending),
        desired(2, external_id: nil),
        desired(3, external_id: "missing")
      ]

      diff = Reconciliation.compute_diff(desired, [])
      assert Enum.map(diff.to_deploy, & &1.id) == [1, 2, 3]
    end
  end

  # -- update / restart / in_sync classification --------------------------

  describe "existing-service classification" do
    test "failed state takes precedence over an image change (restart, not update)" do
      desired = [desired(1, external_id: "svc_1", computed_spec: %{image: "app:2.0"})]
      actual = [service("svc_1", state: :failed, image: "app:1.0")]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.map(diff.to_restart, & &1.id) == [1]
      assert diff.to_update == []
    end

    test "matching image is in_sync even if other fields differ" do
      desired = [desired(1, external_id: "svc_1", computed_spec: %{image: "app:1.0"})]
      actual = [service("svc_1", image: "app:1.0", replicas: 99, name: "renamed")]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.map(diff.in_sync, & &1.id) == [1]
    end

    test "string-keyed image is preferred when atom key is absent" do
      desired = [desired(1, external_id: "svc_1", computed_spec: %{"image" => "app:2.0"})]
      actual = [service("svc_1", image: "app:1.0")]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.map(diff.to_update, & &1.id) == [1]
    end

    test "atom image key wins over string image key" do
      # atom key resolves first; matches actual -> in_sync despite stale string key
      spec = %{:image => "app:1.0", "image" => "app:9.9"}
      desired = [desired(1, external_id: "svc_1", computed_spec: spec)]
      actual = [service("svc_1", image: "app:1.0")]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.map(diff.in_sync, & &1.id) == [1]
    end

    test "empty computed_spec map (no image) is treated as in_sync" do
      desired = [desired(1, external_id: "svc_1", computed_spec: %{})]
      actual = [service("svc_1", image: "anything:1.0")]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.map(diff.in_sync, & &1.id) == [1]
    end
  end

  # -- ordering preservation across reverse/reduce ------------------------

  describe "ordering across categories" do
    test "to_update, to_restart and in_sync preserve desired input order" do
      desired = [
        desired(1, external_id: "u1", computed_spec: %{image: "v2"}),
        desired(2, external_id: "r1"),
        desired(3, external_id: "s1", computed_spec: %{image: "v1"}),
        desired(4, external_id: "u2", computed_spec: %{image: "v2"}),
        desired(5, external_id: "r2"),
        desired(6, external_id: "s2", computed_spec: %{image: "v1"})
      ]

      actual = [
        service("u1", image: "v1"),
        service("r1", state: :failed),
        service("s1", image: "v1"),
        service("u2", image: "v1"),
        service("r2", state: :failed),
        service("s2", image: "v1")
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.map(diff.to_update, & &1.id) == [1, 4]
      assert Enum.map(diff.to_restart, & &1.id) == [2, 5]
      assert Enum.map(diff.in_sync, & &1.id) == [3, 6]
    end
  end

  # -- removal / managed protection ---------------------------------------

  describe "to_remove branches" do
    test "managed orphan whose id is not a desired external_id is removed" do
      actual = [service("orphan", labels: %{"homelab.managed" => "true"})]

      diff = Reconciliation.compute_diff([], actual)
      assert Enum.map(diff.to_remove, & &1.id) == ["orphan"]
    end

    test "unmanaged service is never removed regardless of desired set" do
      actual = [service("ext", labels: %{})]

      diff = Reconciliation.compute_diff([], actual)
      assert diff.to_remove == []
    end

    test "managed flag with non-\"true\" value is not removed" do
      actual = [service("svc", labels: %{"homelab.managed" => "false"})]

      diff = Reconciliation.compute_diff([], actual)
      assert diff.to_remove == []
    end

    test "managed service matching a desired external_id is protected from removal" do
      desired = [desired(1, external_id: "kept", computed_spec: %{image: "app:1.0"})]
      actual = [service("kept", image: "app:1.0")]

      diff = Reconciliation.compute_diff(desired, actual)
      assert diff.to_remove == []
      assert Enum.map(diff.in_sync, & &1.id) == [1]
    end

    test "nil desired external_ids are rejected from the protection set" do
      # A desired record with nil external_id must NOT shield an unrelated
      # managed orphan from removal (reject(&is_nil/1) branch).
      desired = [desired(1, external_id: nil, status: :pending)]
      actual = [service("orphan", labels: %{"homelab.managed" => "true"})]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.map(diff.to_deploy, & &1.id) == [1]
      assert Enum.map(diff.to_remove, & &1.id) == ["orphan"]
    end

    test "removes multiple managed orphans while keeping matched ones" do
      desired = [desired(1, external_id: "keep", computed_spec: %{image: "v1"})]

      actual = [
        service("keep", image: "v1"),
        service("orphan_a", labels: %{"homelab.managed" => "true"}),
        service("orphan_b", labels: %{"homelab.managed" => "true"}),
        service("not_mine", labels: %{})
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert Enum.sort(Enum.map(diff.to_remove, & &1.id)) == ["orphan_a", "orphan_b"]
    end
  end

  # -- whole-result invariants --------------------------------------------

  describe "result invariants" do
    test "every desired record lands in exactly one desired-facing bucket" do
      desired = [
        desired(1, status: :pending),
        desired(2, external_id: "u", computed_spec: %{image: "v2"}),
        desired(3, external_id: "r"),
        desired(4, external_id: "s", computed_spec: %{image: "v1"})
      ]

      actual = [
        service("u", image: "v1"),
        service("r", state: :failed),
        service("s", image: "v1")
      ]

      diff = Reconciliation.compute_diff(desired, actual)

      placed =
        (diff.to_deploy ++ diff.to_update ++ diff.to_restart ++ diff.in_sync)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert placed == [1, 2, 3, 4]
    end
  end
end
