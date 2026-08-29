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

  Rows whose domain is a single canonical hostname are left completely alone, as is any
  value this cannot split — repair here means recovering a meaning that is still there,
  never discarding one that is not.
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

  # Gated on `multi_host?/1`, the SAME predicate the forms split on, rather than on a raw
  # `split/1`. That distinction is the whole rule: `split/1` breaks on whitespace, so
  # `not a host` yields three pieces and `coming soon` yields two -- and splitting those
  # turns an operator's text into a `domain` of `not` plus junk alias rows, destroying
  # what they typed and leaving entries that block the next settings save. It is the very
  # thing the moduledoc rejects about nulling, only worse, because nulling at least does
  # not invent data.
  #
  # So: split what is genuinely several hostnames, canonicalize what is genuinely one,
  # and leave everything else exactly as it is.
  defp repair(%{id: id, domain: domain} = row) do
    cond do
      # Several genuine hostnames written as one field. The case this migration exists for.
      Hostname.multi_host?(domain) ->
        [primary | aliases] = Hostname.split(domain)
        write_row(id, primary, merge_aliases(row.additional_domains, aliases))

      # One hostname, stored non-canonically (a trailing dot, capitals, a pasted scheme).
      # Worth rewriting so the stored string matches the router name and the ACME
      # identifier derived from it.
      Hostname.valid?(domain) and Hostname.normalize(domain) != domain ->
        write_row(id, Hostname.normalize(domain), row.additional_domains)

      # Already canonical, or not a hostname at all. A value this cannot SPLIT is left
      # alone: repair means recovering a meaning that is still there, and an unrecoverable
      # one stays visible in Settings where it can be corrected (the changeset validates
      # what is being WRITTEN, so a bad legacy value no longer blocks the edit that would
      # fix it).
      true ->
        :ok
    end
  end

  defp write_row(id, domain, additional_domains) do
    repo().update_all(
      from(d in "deployments", where: d.id == ^id),
      set: [domain: domain, additional_domains: additional_domains]
    )
  end

  # Normalized on both sides. `existing` comes straight out of the database and may hold
  # any spelling an operator typed before there was anything to canonicalize it; `hosts`
  # is already normalized by `Hostname.split/1`. Comparing raw would let a row reading
  # `Matrix.Example.com` sit alongside a lifted `matrix.example.com` -- one host, two
  # routers, two ACME orders.
  defp merge_aliases(existing, hosts) do
    existing = List.wrap(existing)
    known = MapSet.new(existing, &Hostname.normalize(&1["host"]))

    existing ++
      for host <- hosts, not MapSet.member?(known, Hostname.normalize(host)) do
        %{"host" => host, "path_prefix" => nil, "port" => nil}
      end
  end
end
