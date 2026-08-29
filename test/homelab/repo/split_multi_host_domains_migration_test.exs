defmodule Homelab.Repo.SplitMultiHostDomainsMigrationTest do
  @moduledoc """
  The repair migration for rows written before `domain` was validated.

  It is the only piece of this change that touches production data, and the rows it acts
  on are by definition ones no changeset would accept — so it is exercised against raw
  inserts, the way those rows actually exist.
  """
  use Homelab.DataCase, async: false

  import Ecto.Query
  import Homelab.Factory

  alias Ecto.Migration.Runner
  alias Homelab.Deployments.Deployment
  alias Homelab.Deployments.SpecBuilder
  alias Homelab.Repo

  @migration Homelab.Repo.Migrations.SplitMultiHostDeploymentDomains

  setup_all do
    Code.require_file(
      "priv/repo/migrations/20260828000000_split_multi_host_deployment_domains.exs"
    )

    :ok
  end

  # Around the changeset on purpose: every value worth repairing is one the changeset now
  # rejects, so a factory insert is the only way to recreate the starting state.
  defp legacy_row(domain, additional_domains \\ []) do
    tenant = insert(:tenant)
    template = insert(:app_template)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {1, [id]} =
      Repo.insert_all(
        "deployments",
        [
          %{
            tenant_id: tenant.id,
            app_template_id: template.id,
            status: "running",
            domain: domain,
            additional_domains: additional_domains,
            env_overrides: %{},
            proxy_options: %{},
            extra_routes: [],
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: [:id]
      )

    id.id
  end

  defp migrate do
    Runner.run(Repo, [], 1, @migration, :forward, :up, :up, log: false)
  end

  defp read(id) do
    Repo.one!(
      from(d in "deployments",
        where: d.id == ^id,
        select: %{domain: d.domain, additional_domains: d.additional_domains}
      )
    )
  end

  test "the comma-joined value becomes a primary plus an alias" do
    id = legacy_row("communication.ventures,matrix.communication.ventures")

    migrate()

    assert read(id) == %{
             domain: "communication.ventures",
             additional_domains: [
               %{
                 "host" => "matrix.communication.ventures",
                 "path_prefix" => nil,
                 "port" => nil
               }
             ]
           }
  end

  # The overwhelmingly common row. Rewriting it would churn every deployment in the
  # database for nothing, so the `[^domain] -> :ok` branch has to actually hold.
  test "a single canonical hostname is left completely alone" do
    id = legacy_row("app.example.com", [%{"host" => "chat.example.com"}])
    before = read(id)

    migrate()

    assert read(id) == before
  end

  test "a single non-canonical hostname is rewritten to its canonical form" do
    # The stored string becomes a router name and an ACME identifier, so a stray trailing
    # dot or capital is worth repairing even though it routes.
    id = legacy_row("HTTPS://App.Example.COM/")

    migrate()

    assert %{domain: "app.example.com"} = read(id)
  end

  # Repair means recovering a meaning that is still there. Nulling an unrecoverable value
  # is a different act: the operator loses the record of what they typed, and the app
  # quietly goes from broken-and-routed to working-and-unrouted.
  test "a value that cannot be split is left alone, not cleared" do
    for junk <- ["!!!", "   ,  , ", "not_a_host"] do
      id = legacy_row(junk)
      before = read(id)

      migrate()

      assert read(id) == before, "#{inspect(junk)} should have been left untouched"
    end
  end

  test "lifted aliases are appended to existing ones, never replacing them" do
    id =
      legacy_row("a.example.com b.example.com", [
        %{"host" => "existing.example.com", "path_prefix" => "/keep", "port" => 9000}
      ])

    migrate()

    assert %{domain: "a.example.com", additional_domains: aliases} = read(id)

    assert [
             %{"host" => "existing.example.com", "path_prefix" => "/keep", "port" => 9000},
             %{"host" => "b.example.com", "path_prefix" => nil, "port" => nil}
           ] = aliases
  end

  test "a lifted alias already present in another spelling is not duplicated" do
    id =
      legacy_row("a.example.com, b.example.com", [
        %{"host" => "B.Example.COM", "path_prefix" => "/scoped", "port" => nil}
      ])

    migrate()

    assert %{additional_domains: aliases} = read(id)

    assert length(aliases) == 1, "expected the differently-spelled row to dedupe"
    assert [%{"path_prefix" => "/scoped"}] = aliases
  end

  test "a row with no domain is untouched" do
    id = legacy_row(nil)

    migrate()

    assert %{domain: nil, additional_domains: []} = read(id)
  end

  test "running it twice changes nothing the second time" do
    id = legacy_row("communication.ventures,matrix.communication.ventures")

    migrate()
    once = read(id)
    migrate()

    assert read(id) == once
  end

  test "the repaired row builds one Traefik router per host" do
    id = legacy_row("communication.ventures,matrix.communication.ventures")

    migrate()

    deployment =
      Deployment
      |> Repo.get!(id)
      |> Repo.preload([:tenant, :app_template])

    assert {:ok, spec} = SpecBuilder.build(deployment)

    rules =
      spec.labels
      |> Enum.filter(fn {k, _v} -> String.ends_with?(k, ".rule") end)
      |> Enum.map(fn {_k, v} -> v end)
      |> Enum.sort()

    assert rules == [
             "Host(`communication.ventures`)",
             "Host(`matrix.communication.ventures`)"
           ]
  end
end
