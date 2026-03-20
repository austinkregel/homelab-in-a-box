defmodule Homelab.ReconciliationTest do
  use ExUnit.Case, async: true

  alias Homelab.Reconciliation
  alias Homelab.Reconciliation.Diff

  describe "compute_diff/2" do
    test "returns empty diff when both lists are empty" do
      diff = Reconciliation.compute_diff([], [])
      assert %Diff{} = diff
      assert diff.to_deploy == []
      assert diff.to_remove == []
      assert diff.to_restart == []
      assert diff.to_update == []
      assert diff.in_sync == []
    end

    test "identifies pending deployments as needing deploy" do
      desired = [
        %{id: 1, external_id: nil, status: :pending, computed_spec: %{image: "app:1.0"}}
      ]

      diff = Reconciliation.compute_diff(desired, [])
      assert length(diff.to_deploy) == 1
      assert hd(diff.to_deploy).id == 1
      assert diff.to_remove == []
      assert diff.to_restart == []
    end

    test "identifies deployments with missing external services as needing deploy" do
      desired = [
        %{id: 1, external_id: "svc_gone", status: :running, computed_spec: %{image: "app:1.0"}}
      ]

      actual = []

      diff = Reconciliation.compute_diff(desired, actual)
      assert length(diff.to_deploy) == 1
    end

    test "identifies orphaned managed services for removal" do
      desired = []

      actual = [
        %{
          id: "orphan_svc",
          name: "old_app",
          state: :running,
          replicas: 1,
          image: "old:latest",
          labels: %{"homelab.managed" => "true"}
        }
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert length(diff.to_remove) == 1
      assert hd(diff.to_remove).id == "orphan_svc"
    end

    test "does not remove non-managed services" do
      desired = []

      actual = [
        %{
          id: "external_svc",
          name: "someone_elses",
          state: :running,
          replicas: 1,
          image: "x:1",
          labels: %{}
        }
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert diff.to_remove == []
    end

    test "identifies failed services for restart" do
      desired = [
        %{id: 1, external_id: "svc_1", status: :running, computed_spec: %{image: "app:1.0"}}
      ]

      actual = [
        %{
          id: "svc_1",
          name: "app",
          state: :failed,
          replicas: 0,
          image: "app:1.0",
          labels: %{"homelab.managed" => "true"}
        }
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert length(diff.to_restart) == 1
      assert hd(diff.to_restart).id == 1
    end

    test "identifies services needing update when image changed" do
      desired = [
        %{id: 1, external_id: "svc_1", status: :running, computed_spec: %{image: "app:2.0"}}
      ]

      actual = [
        %{
          id: "svc_1",
          name: "app",
          state: :running,
          replicas: 1,
          image: "app:1.0",
          labels: %{"homelab.managed" => "true"}
        }
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert length(diff.to_update) == 1
    end

    test "identifies in-sync services" do
      desired = [
        %{id: 1, external_id: "svc_1", status: :running, computed_spec: %{image: "app:1.0"}}
      ]

      actual = [
        %{
          id: "svc_1",
          name: "app",
          state: :running,
          replicas: 1,
          image: "app:1.0",
          labels: %{"homelab.managed" => "true"}
        }
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert length(diff.in_sync) == 1
      assert diff.to_deploy == []
      assert diff.to_remove == []
      assert diff.to_restart == []
      assert diff.to_update == []
    end

    test "handles mixed scenario with multiple actions" do
      desired = [
        # needs deploy (pending)
        %{id: 1, external_id: nil, status: :pending, computed_spec: %{image: "new:1.0"}},
        # in sync
        %{id: 2, external_id: "svc_2", status: :running, computed_spec: %{image: "app:1.0"}},
        # needs restart (failed)
        %{id: 3, external_id: "svc_3", status: :running, computed_spec: %{image: "other:1.0"}},
        # needs update (image changed)
        %{id: 4, external_id: "svc_4", status: :running, computed_spec: %{image: "app:2.0"}}
      ]

      actual = [
        %{
          id: "svc_2",
          name: "app",
          state: :running,
          replicas: 1,
          image: "app:1.0",
          labels: %{"homelab.managed" => "true"}
        },
        %{
          id: "svc_3",
          name: "other",
          state: :failed,
          replicas: 0,
          image: "other:1.0",
          labels: %{"homelab.managed" => "true"}
        },
        %{
          id: "svc_4",
          name: "app2",
          state: :running,
          replicas: 1,
          image: "app:1.0",
          labels: %{"homelab.managed" => "true"}
        },
        # orphan to remove
        %{
          id: "svc_orphan",
          name: "old",
          state: :running,
          replicas: 1,
          image: "old:1.0",
          labels: %{"homelab.managed" => "true"}
        }
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert length(diff.to_deploy) == 1
      assert length(diff.to_remove) == 1
      assert length(diff.to_restart) == 1
      assert length(diff.to_update) == 1
      assert length(diff.in_sync) == 1
    end

    test "handles string image keys in computed_spec" do
      desired = [
        %{id: 1, external_id: "svc_1", status: :running, computed_spec: %{"image" => "app:2.0"}}
      ]

      actual = [
        %{
          id: "svc_1",
          name: "app",
          state: :running,
          replicas: 1,
          image: "app:1.0",
          labels: %{"homelab.managed" => "true"}
        }
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert length(diff.to_update) == 1
    end

    test "treats nil computed_spec image as in-sync" do
      desired = [
        %{id: 1, external_id: "svc_1", status: :running, computed_spec: nil}
      ]

      actual = [
        %{
          id: "svc_1",
          name: "app",
          state: :running,
          replicas: 1,
          image: "app:1.0",
          labels: %{"homelab.managed" => "true"}
        }
      ]

      diff = Reconciliation.compute_diff(desired, actual)
      assert length(diff.in_sync) == 1
    end
  end
end
