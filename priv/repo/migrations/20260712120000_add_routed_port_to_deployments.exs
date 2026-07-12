defmodule Homelab.Repo.Migrations.AddRoutedPortToDeployments do
  use Ecto.Migration

  # The container port the reverse proxy forwards to.
  #
  # This used to be inferred: SpecBuilder picked the first port whose `role` was
  # "web", and PortRoles.infer/1 hands "web" to *every* conventional HTTP port
  # (8000 and 8080 are both in the list). An app exposing two of them had its
  # upstream chosen by array order, and an operator's explicit pick was re-inferred
  # away on the next save -- which pointed Traefik at a port nothing listened on
  # and served a 502.
  #
  # A routing decision must be stored as a decision. NULL = no decision on record,
  # fall back to the old heuristic.
  def change do
    alter table(:deployments) do
      add :routed_port, :integer
    end
  end
end
