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

    # Tables now exist — warm the settings ETS cache so cache-only reads
    # (e.g. storage roots) see DB-persisted overrides after a restart. Guarded:
    # a fresh/unavailable DB (or the test sandbox at boot) must not break boot.
    _ = warm_settings_cache()

    :ignore
  end

  defp warm_settings_cache do
    Homelab.Settings.warm_cache()
  rescue
    _ -> :ok
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
