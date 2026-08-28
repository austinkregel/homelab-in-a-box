defmodule Homelab.Repo.Migrations.SplitMultiHostDeploymentDomains do
  use Ecto.Migration

  # Only `from/2` -- a bare `import Ecto.Query` also brings in `update/3`, which
  # collides with this module's own row-writing helper.
  import Ecto.Query, only: [from: 2]

  alias Homelab.Networking.Hostname

  @moduledoc """
  Repair deployments whose `domain` holds several hostnames in one string.

  `domain` was cast as a bare string with nothing validating it, and the wizard offered
  one input for it, so an operator with a root domain and a subdomain separated them the
  way any other tool would accept: `communication.ventures,matrix.communication.ventures`.

  That value was emitted whole. Traefik got one router whose rule was
  ``Host(`communication.ventures,matrix.communication.ventures`)``, failed to build it,
  and said so once at startup; Let's Encrypt got an ACME order for an identifier that
  cannot exist and rejected it. The app was reachable on neither name, and nothing
  connected either symptom back to the field that caused it.

  The schema now rejects such a value and both forms split it before it gets there — but
  neither touches a row already written. This does: the first hostname stays the primary
  `domain`, every other one becomes an `additional_domains` entry, which is the same
  outcome the forms now produce and (unlike simply nulling the field) preserves what the
  operator actually asked for. Aliases are appended, never replacing entries that are
  already there.

  Rows whose domain is a single valid hostname are left completely alone.
  """

  def up do
    # Raw SQL over the two columns rather than the schema: a migration must keep working
    # when the struct around it changes, and the changeset would now REJECT exactly the
    # rows this exists to read.
    query =
      from(d in "deployments",
        where: not is_nil(d.domain) and d.domain != "",
        select: %{id: d.id, domain: d.domain, additional_domains: d.additional_domains}
      )

    query
    |> repo().all()
    |> Enum.each(&repair/1)
  end

  # There is no honest reverse. Down would have to re-join hosts into one field, which is
  # to say re-create an unroutable value — and it could not tell an alias this migration
  # lifted out of `domain` from one the operator added by hand afterwards.
  def down, do: :ok

  defp repair(%{id: id, domain: domain} = row) do
    case Hostname.split(domain) do
      # The overwhelmingly common case: one host, already fine.
      [^domain] ->
        :ok

      # One host, but not in canonical form (trailing dot, capitals, a pasted scheme).
      # Worth rewriting so the stored string matches the router name and ACME identifier
      # derived from it.
      [single] ->
        write_row(id, single, row.additional_domains)

      [primary | aliases] ->
        write_row(id, primary, merge_aliases(row.additional_domains, aliases))

      # Nothing survives normalization -- the field held punctuation. Leaving it would
      # keep emitting a broken rule, so clear it; the deployment stops being routed,
      # which is what it already effectively was.
      [] ->
        write_row(id, nil, row.additional_domains)
    end
  end

  defp write_row(id, domain, additional_domains) do
    repo().update_all(
      from(d in "deployments", where: d.id == ^id),
      set: [domain: domain, additional_domains: additional_domains]
    )
  end

  defp merge_aliases(existing, hosts) do
    existing = List.wrap(existing)
    known = MapSet.new(existing, & &1["host"])

    existing ++
      for host <- hosts, not MapSet.member?(known, host) do
        %{"host" => host, "path_prefix" => nil, "port" => nil}
      end
  end
end
