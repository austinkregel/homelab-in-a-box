defmodule Homelab.Deployments.ReleaseStepReasonMigrationTest do
  @moduledoc """
  The rename that gave a step's message a type carries the messages already on the table.
  """
  use Homelab.DataCase, async: false

  import Homelab.Factory

  alias Ecto.Adapters.SQL
  alias Homelab.Deployments.Releases
  alias Homelab.Repo

  @version 20_260_907_130_000
  @path "priv/repo/migrations/20260907130000_add_stage_and_reason_to_release_steps.exs"
  @migration Homelab.Repo.Migrations.AddStageAndReasonToReleaseSteps

  setup do
    unless Code.ensure_loaded?(@migration), do: Code.require_file(Path.expand(@path, File.cwd!()))
    :ok
  end

  test "a step message written before the rename reads back typed as an error" do
    {:ok, release} = Releases.plan_release(insert(:deployment), [%{type: :app_container}])
    [step] = release.steps

    {:ok, _} = Releases.transition_step(step, :failed, [:pending], reason: {"error", "boom"})

    # Back to the pre-rename shape: one `error_message` column and no type at all.
    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, log: false)

    assert %{rows: [["boom"]]} =
             SQL.query!(Repo, "SELECT error_message FROM release_steps WHERE id = $1", [step.id])

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, log: false)

    assert %{rows: [["boom", "error"]]} =
             SQL.query!(
               Repo,
               "SELECT reason_message, reason_type FROM release_steps WHERE id = $1",
               [step.id]
             )
  end
end
