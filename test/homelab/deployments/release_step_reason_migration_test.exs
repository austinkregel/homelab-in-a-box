defmodule Homelab.Deployments.ReleaseStepReasonMigrationTest do
  @moduledoc """
  The rename that gave a step's message a type carries the messages already on the table.
  """
  use Homelab.DataCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]
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

    # `migration_lock: false` is load-bearing, not tidying. With the lock on,
    # `Ecto.Migrator` opens a transaction on the connection to `LOCK TABLE
    # schema_migrations`, and then runs the migration itself in a `Task.async` it
    # `await`s forever. Under the SQL sandbox there is exactly one connection: the test
    # process holds it inside that lock transaction while blocking on the await, and the
    # task cannot check it out. That is a deadlock, and it resolves only when the
    # checkout queue gives up — the test failed after 20s with a
    # `DBConnection.ConnectionError`, every time, not just under CI load.
    #
    # Skipping the lock is safe precisely here: the lock exists to stop two nodes
    # migrating at once, and this is one sandboxed test owning its own transaction.

    # Back to the pre-rename shape: one `error_message` column and no type at all.
    assert :ok = migrate(:down)

    assert %{rows: [["boom"]]} =
             SQL.query!(Repo, "SELECT error_message FROM release_steps WHERE id = $1", [step.id])

    assert :ok = migrate(:up)

    assert %{rows: [["boom", "error"]]} =
             SQL.query!(
               Repo,
               "SELECT reason_message, reason_type FROM release_steps WHERE id = $1",
               [step.id]
             )
  end

  # Wrapped in `capture_log/1` because `Ecto.Migrator` warns whenever it runs a version
  # older than one already applied, and this test deliberately re-runs a historical one.
  # Every migration added after this test's target makes that warning fire, so without
  # this the suite grows a permanent "an older migration has already run" warning that
  # says nothing about the code under test. `log: false` does not cover it -- that option
  # silences the migration's own SQL, not the ordering check.
  defp migrate(direction) do
    opts = [log: false, migration_lock: false]

    {result, _log} =
      with_log(fn -> apply(Ecto.Migrator, direction, [Repo, @version, @migration, opts]) end)

    result
  end
end
