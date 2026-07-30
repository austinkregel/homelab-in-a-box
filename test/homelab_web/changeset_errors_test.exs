defmodule HomelabWeb.ChangesetErrorsTest do
  @moduledoc """
  A refused save has to say why.

  The deployment page answered every `%Ecto.Changeset{}` with "Could not save the
  configuration.", so all ten of `Netns`'s distinct refusals were indistinguishable from
  each other and from a broken feature.
  """
  use ExUnit.Case, async: true

  alias HomelabWeb.ChangesetErrors
  alias Homelab.Deployments.Deployment

  defp changeset(errors) do
    Enum.reduce(errors, Ecto.Changeset.change(%Deployment{}), fn {field, {msg, opts}}, acc ->
      Ecto.Changeset.add_error(acc, field, msg, opts)
    end)
  end

  describe "to_sentence/1" do
    test "a message that names its own subject stands alone" do
      sentence =
        changeset([
          {:network_parent_id,
           {"Docker Swarm cannot share a network namespace between services — this needs " <>
              "the Docker Engine orchestrator", []}}
        ])
        |> ChangesetErrors.to_sentence()

      assert sentence =~ "Docker Swarm cannot share a network namespace"
      refute sentence =~ "Network parent Docker Swarm"
    end

    test "a fragment gets its field, humanized without the _id" do
      sentence =
        changeset([{:network_parent_id, {"must be in the same space", []}}])
        |> ChangesetErrors.to_sentence()

      assert sentence == "Network parent must be in the same space"
    end

    test "an _override column does not announce itself as one" do
      sentence =
        changeset([{:replicas_override, {"cannot be used while routing through another", []}}])
        |> ChangesetErrors.to_sentence()

      assert sentence =~ "Replicas cannot be used"
    end

    test "placeholders are interpolated, not printed" do
      sentence =
        changeset([{:routed_port, {"must be less than %{number}", [number: 65_536]}}])
        |> ChangesetErrors.to_sentence()

      assert sentence == "Routed port must be less than 65536"
      refute sentence =~ "%{number}"
    end

    test "several refusals all survive" do
      sentence =
        changeset([
          {:network_parent_id, {"must be in the same space", []}},
          {:routed_port, {"is invalid", []}}
        ])
        |> ChangesetErrors.to_sentence()

      assert sentence =~ "must be in the same space"
      assert sentence =~ "is invalid"
    end

    test "a changeset with no errors still yields something sayable" do
      assert ChangesetErrors.to_sentence(Ecto.Changeset.change(%Deployment{})) =~
               "Could not save"
    end
  end

  describe "to_map/1" do
    test "keeps the field keys a JSON client needs" do
      map =
        changeset([{:network_parent_id, {"must be in the same space", []}}])
        |> ChangesetErrors.to_map()

      assert map == %{network_parent_id: ["must be in the same space"]}
    end
  end
end
