{:ok, _} = Application.ensure_all_started(:ex_machina)
ExUnit.start(exclude: [:integration])
Ecto.Adapters.SQL.Sandbox.mode(Homelab.Repo, :manual)
