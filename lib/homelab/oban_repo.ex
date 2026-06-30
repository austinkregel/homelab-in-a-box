defmodule Homelab.ObanRepo do
  @moduledoc """
  Dedicated Ecto repo for Oban, pointed at a **separate Postgres instance** from
  the main application database.

  Oban's job table is high-churn (frequent inserts/updates/deletes and, with some
  notifiers, `LISTEN/NOTIFY` traffic). Isolating it on its own instance keeps that
  load off the main app database so it can't degrade request latency.
  """
  use Ecto.Repo,
    otp_app: :homelab,
    adapter: Ecto.Adapters.Postgres
end
