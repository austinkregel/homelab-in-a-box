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

    # Tables now exist — record which orchestrator this host is actually running if
    # nothing is stored yet, BEFORE any service reads it. Same guard as below: a
    # fresh/unavailable DB must not break boot.
    _ = ensure_orchestrator_recorded()

    # Tables now exist — warm the settings ETS cache so cache-only reads
    # (e.g. storage roots) see DB-persisted overrides after a restart. Guarded:
    # a fresh/unavailable DB (or the test sandbox at boot) must not break boot.
    _ = warm_settings_cache()

    :ignore
  end

  # An explicit application-env orchestrator (tests inject a mock) is authoritative
  # and takes precedence over Settings anyway, so there is nothing to record.
  defp ensure_orchestrator_recorded do
    if is_nil(Application.get_env(:homelab, :orchestrator)) do
      Homelab.Bootstrap.backfill_orchestrator()
    end
  rescue
    _ -> :ok
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
