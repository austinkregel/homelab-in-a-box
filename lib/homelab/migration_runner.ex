defmodule Homelab.MigrationRunner do
  @moduledoc """
  Runs Ecto migrations synchronously as a supervision tree child.

  Placed between Repo and ServicesSupervisor in the boot order so that
  all tables exist before any service GenServer queries the database.
  Returns `:ignore` after completion — no long-lived process needed.
  """

  require Logger

  def start_link(_opts) do
    if Application.get_env(:homelab, :bootstrap, false) do
      Homelab.Bootstrap.run_migrations()
    else
      Homelab.Bootstrap.maybe_seed_from_env()
    end

    :ignore
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end
end
