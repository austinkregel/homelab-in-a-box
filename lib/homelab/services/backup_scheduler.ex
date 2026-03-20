defmodule Homelab.Services.BackupScheduler do
  @moduledoc """
  Periodically checks for due backup jobs and dispatches them
  to the Task.Supervisor for execution.
  """

  use GenServer
  require Logger

  @default_interval :timer.minutes(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    enabled = Keyword.get(opts, :enabled, true)

    if enabled do
      jitter = :rand.uniform(:timer.seconds(8))
      Process.send_after(self(), :check_schedules, jitter)
    end

    {:ok, %{interval: interval, enabled: enabled, last_check_at: nil, jobs_dispatched: 0}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    send(self(), :check_schedules)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_schedules, state) do
    now = DateTime.utc_now()
    due_jobs = Homelab.Backups.list_due_backups(now)

    dispatched =
      Enum.count(due_jobs, fn job ->
        case Task.Supervisor.start_child(
               Homelab.Workers.TaskSupervisor,
               fn -> Homelab.Backups.execute_backup(job) end
             ) do
          {:ok, _pid} ->
            true

          {:error, reason} ->
            Logger.error("Failed to dispatch backup job #{job.id}: #{inspect(reason)}")
            false
        end
      end)

    Process.send_after(self(), :check_schedules, state.interval)

    {:noreply,
     %{
       state
       | last_check_at: DateTime.utc_now(),
         jobs_dispatched: state.jobs_dispatched + dispatched
     }}
  end
end
