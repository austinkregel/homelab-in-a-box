defmodule Homelab.Repo.Migrations.AddNetnsDonorKindToAppTemplates do
  use Ecto.Migration

  # What KIND of network donor this image is, when it is one at all (NULL = not a
  # donor / nothing image-specific to do).
  #
  # Sharing a namespace is generic; making the shared namespace usable is not. Gluetun
  # runs a firewall that DROPS everything not destined for the tunnel, so a child's
  # port is unreachable unless it is listed in FIREWALL_INPUT_PORTS, and the reply is
  # dropped unless the Docker subnets are in FIREWALL_OUTBOUND_SUBNETS. Both are
  # derivable from what the plane already knows — the children's routed ports and the
  # networks it created — and getting them wrong produces a 502 through Traefik with
  # nothing in any log to explain it. It is the single most common way this pattern
  # fails.
  #
  # A discriminator rather than a boolean so a second donor image with different env
  # var names does not have to pretend to be gluetun.
  def change do
    alter table(:app_templates) do
      add :netns_donor_kind, :string
    end
  end
end
