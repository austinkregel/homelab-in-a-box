defmodule Homelab.Repo.Migrations.AddExtraRoutesToDeployments do
  use Ecto.Migration

  # Additional path -> container-port routes for one deployment.
  #
  # The routing model assumed a workload had exactly ONE backend port: one Traefik
  # router, one service, `routed_port`. That holds until an app serves a second
  # protocol from a second port in the same container.
  #
  # aut.hair does. Laravel answers on 8000 and Reverb (websockets) on 6001, and the
  # browser reaches Reverb at wss://aut.hair/app -- port 443, path /app. With one
  # backend port there was no way to say "/app goes to 6001", so every websocket
  # handshake landed on the HTTP server, which does not speak it.
  #
  # Each entry: %{"path_prefix" => "/app", "port" => 6001}.
  def change do
    alter table(:deployments) do
      add :extra_routes, {:array, :map}, default: [], null: false
    end
  end
end
