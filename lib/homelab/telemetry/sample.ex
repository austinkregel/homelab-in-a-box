defmodule Homelab.Telemetry.Sample do
  @moduledoc """
  A single time-series telemetry data point in `metric_samples`.

  Rows are written in bulk via `Homelab.Telemetry.record_snapshot/2` (using
  `Repo.insert_all`), so there is no changeset here — the context is the only
  writer and builds validated rows directly.
  """
  use Ecto.Schema

  @type t :: %__MODULE__{}

  @primary_key false
  schema "metric_samples" do
    field :recorded_at, :utc_datetime_usec
    field :source, :string
    field :subject, :string
    field :metric, :string
    field :value, :float
  end
end
