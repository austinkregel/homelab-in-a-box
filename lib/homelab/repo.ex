defmodule Homelab.Repo do
  use Ecto.Repo,
    otp_app: :homelab,
    adapter: Ecto.Adapters.Postgres
end
