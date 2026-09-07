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
    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, log: false, migration_lock: false)

    assert %{rows: [["boom"]]} =
             SQL.query!(Repo, "SELECT error_message FROM release_steps WHERE id = $1", [step.id])

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, log: false, migration_lock: false)

    assert %{rows: [["boom", "error"]]} =
             SQL.query!(
               Repo,
               "SELECT reason_message, reason_type FROM release_steps WHERE id = $1",
               [step.id]
             )
  end
end
