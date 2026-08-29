defmodule Homelab.Deployments.DeploymentSchemaTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Repo
  alias Homelab.Deployments.Deployment
  alias Homelab.Networking.Hostname

  describe "changeset/2 required & optional fields" do
    test "valid with only required fields, status defaults to :pending" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id
        })

      assert changeset.valid?

      deployment = Ecto.Changeset.apply_changes(changeset)
      assert deployment.status == :pending
      assert deployment.env_overrides == %{}
    end

    test "is invalid when tenant_id is missing" do
      template = insert(:app_template)

      changeset = Deployment.changeset(%Deployment{}, %{app_template_id: template.id})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).tenant_id
    end

    test "is invalid when app_template_id is missing" do
      tenant = insert(:tenant)

      changeset = Deployment.changeset(%Deployment{}, %{tenant_id: tenant.id})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).app_template_id
    end

    test "is invalid when both required fields are missing" do
      changeset = Deployment.changeset(%Deployment{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.tenant_id
      assert "can't be blank" in errors.app_template_id
    end

    test "casts all optional fields" do
      tenant = insert(:tenant)
      template = insert(:app_template)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id,
          status: :running,
          external_id: "ext-123",
          domain: "app.example.com",
          env_overrides: %{"FOO" => "bar"},
          computed_spec: %{"image" => "x"},
          last_reconciled_at: now,
          error_message: "boom"
        })

      assert changeset.valid?
      d = Ecto.Changeset.apply_changes(changeset)
      assert d.status == :running
      assert d.external_id == "ext-123"
      assert d.domain == "app.example.com"
      assert d.env_overrides == %{"FOO" => "bar"}
      assert d.computed_spec == %{"image" => "x"}
      assert d.last_reconciled_at == now
      assert d.error_message == "boom"
    end
  end

  describe "changeset/2 domain validation" do
    setup do
      %{tenant: insert(:tenant), template: insert(:app_template)}
    end

    defp domain_changeset(tenant, template, domain) do
      Deployment.changeset(%Deployment{}, %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        domain: domain
      })
    end

    test "accepts an ordinary hostname", %{tenant: tenant, template: template} do
      changeset = domain_changeset(tenant, template, "matrix.communication.ventures")

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).domain == "matrix.communication.ventures"
    end

    test "stores the canonical form of what was typed", %{tenant: tenant, template: template} do
      # The stored string becomes a Traefik router name and an ACME identifier, so two
      # spellings of one host must not become two of either.
      changeset = domain_changeset(tenant, template, " HTTPS://Matrix.Example.COM/ ")

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).domain == "matrix.example.com"
    end

    test "rejects the comma-joined value, naming where the rest belongs", %{
      tenant: tenant,
      template: template
    } do
      # This exact value reached Traefik whole and became one router with the rule
      # ``Host(`communication.ventures,matrix.communication.ventures`)``, which Traefik
      # could not build and Let's Encrypt would not issue for.
      changeset =
        domain_changeset(tenant, template, "communication.ventures,matrix.communication.ventures")

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).domain, &(&1 =~ "single hostname"))
      assert Enum.any?(errors_on(changeset).domain, &(&1 =~ "additional domains"))
    end

    test "rejects a value that is not a hostname at all", %{tenant: tenant, template: template} do
      changeset = domain_changeset(tenant, template, "not_a_host")

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).domain, &(&1 =~ "not a valid hostname"))
    end

    test "typed prose gets the format error, not the split-it-up one", %{
      tenant: tenant,
      template: template
    } do
      # Splitting on whitespace means any sentence yields several pieces. Telling someone
      # who typed this to "list the rest under additional domains" sends them looking for
      # a second hostname they never had.
      changeset = domain_changeset(tenant, template, "not a host!")

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).domain, &(&1 =~ "not a valid hostname"))
    end

    test "rejects a single label", %{tenant: tenant, template: template} do
      changeset = domain_changeset(tenant, template, "synapse")

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).domain, &(&1 =~ "not a valid hostname"))
    end

    test "a blank domain is nil, not an error -- routing is optional", %{
      tenant: tenant,
      template: template
    } do
      changeset = domain_changeset(tenant, template, "")

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).domain == nil
    end

    test "an absent domain is left alone", %{tenant: tenant, template: template} do
      changeset =
        Deployment.changeset(%Deployment{}, %{tenant_id: tenant.id, app_template_id: template.id})

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).domain == nil
    end

    # Validation is scoped to what is being WRITTEN. Reading the persisted value instead
    # would run this check on every update, including the overwhelming majority that
    # never mention the field -- and any row stored before the validation existed would
    # become permanently un-updatable. The paths that break are the hot ones:
    # `update_deployment/2` setting `status: :pending` on redeploy, the container and
    # reclaim steps, storage.
    test "a legacy row with an invalid stored domain still accepts unrelated updates", %{
      tenant: tenant,
      template: template
    } do
      for stored <- ["nextcloud", "under_score.example.com", ""] do
        # Inserted around the changeset, which is how such a row got into a database
        # before there was anything to reject it.
        legacy = insert(:deployment, tenant: tenant, app_template: template, domain: stored)

        changeset = Deployment.changeset(legacy, %{status: :running})

        assert changeset.valid?,
               "a #{inspect(stored)} domain blocked an unrelated update: " <>
                 inspect(changeset.errors)

        assert changeset.changes == %{status: :running}
      end
    end

    test "but EDITING the domain to an invalid value is still rejected", %{
      tenant: tenant,
      template: template
    } do
      legacy = insert(:deployment, tenant: tenant, app_template: template, domain: "nextcloud")

      changeset = Deployment.changeset(legacy, %{domain: "still_not_valid"})

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).domain, &(&1 =~ "not a valid hostname"))
    end

    # The composition the FORMS perform: split the field, then hand both halves to the
    # changeset. `validate_domain/1` reasons carefully that a value must be wholly
    # hostnames before it is called several -- and that reasoning is worthless if the form
    # has already split it before the changeset ever sees it.
    #
    # Under a naive split this exact value yields THREE errors across two fields: a
    # `domain` of "not", plus aliases "a" and "host!" the operator never typed.
    test "a typo stays one error on one field through the form's split", %{
      tenant: tenant,
      template: template
    } do
      {primary, aliases} = Hostname.split_primary("not a host!")

      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id,
          domain: primary,
          additional_domains:
            Enum.map(aliases, &%{"host" => &1, "path_prefix" => nil, "port" => nil})
        })

      refute changeset.valid?

      assert Map.keys(errors_on(changeset)) == [:domain]
      assert errors_on(changeset).domain == ["is not a valid hostname"]
    end

    test "a legacy row can be repaired through the changeset", %{
      tenant: tenant,
      template: template
    } do
      legacy = insert(:deployment, tenant: tenant, app_template: template, domain: "nextcloud")

      changeset = Deployment.changeset(legacy, %{domain: "nextcloud.example.com"})

      assert changeset.valid?
      assert Ecto.Changeset.apply_changes(changeset).domain == "nextcloud.example.com"
    end
  end

  describe "changeset/2 additional_domains validation" do
    setup do
      %{tenant: insert(:tenant), template: insert(:app_template)}
    end

    defp domains_changeset(tenant, template, domains) do
      Deployment.changeset(%Deployment{}, %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        additional_domains: domains
      })
    end

    test "a host-only entry is valid (whole host to the routed port)", %{
      tenant: tenant,
      template: template
    } do
      changeset = domains_changeset(tenant, template, [%{"host" => "chat.example.com"}])
      assert changeset.valid?
    end

    test "a path- and port-scoped entry is valid", %{tenant: tenant, template: template} do
      changeset =
        domains_changeset(tenant, template, [
          %{"host" => "example.com", "path_prefix" => "/.well-known/matrix", "port" => 8008}
        ])

      assert changeset.valid?
    end

    test "a blank/missing host is rejected", %{tenant: tenant, template: template} do
      changeset = domains_changeset(tenant, template, [%{"path_prefix" => "/x"}])

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).additional_domains, &(&1 =~ "host is required"))
    end

    test "a host without a dot is rejected (catches a path typed into the host field)", %{
      tenant: tenant,
      template: template
    } do
      changeset = domains_changeset(tenant, template, [%{"host" => "notafqdn"}])

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).additional_domains, &(&1 =~ "must be a domain"))
    end

    test "a present but malformed path is rejected", %{tenant: tenant, template: template} do
      changeset =
        domains_changeset(tenant, template, [%{"host" => "example.com", "path_prefix" => "x"}])

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).additional_domains, &(&1 =~ "path must start with /"))
    end

    test "a present but out-of-range port is rejected", %{tenant: tenant, template: template} do
      changeset =
        domains_changeset(tenant, template, [%{"host" => "example.com", "port" => 70_000}])

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).additional_domains, &(&1 =~ "port must be 1-65535"))
    end

    test "a comma-joined host is rejected here too", %{tenant: tenant, template: template} do
      # The hand-rolled check this replaced excluded spaces and slashes but not commas,
      # so an alias row could carry the very value the primary field now rejects and land
      # the same unbuildable rule one router over.
      changeset =
        domains_changeset(tenant, template, [
          %{"host" => "communication.ventures,matrix.communication.ventures"}
        ])

      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).additional_domains, &(&1 =~ "must be a domain"))
    end

    test "an alias host is stored canonically", %{tenant: tenant, template: template} do
      changeset = domains_changeset(tenant, template, [%{"host" => "https://Chat.Example.COM/"}])

      assert changeset.valid?

      assert [%{"host" => "chat.example.com"}] =
               Ecto.Changeset.apply_changes(changeset).additional_domains
    end

    # A bare alias naming the deployment's own domain is not a second host -- it derives
    # the SAME router name, so its labels overwrite the base router's in the merged map.
    # With a `port` on it, that silently repoints the PRIMARY route's backend away from
    # `routed_port`, which presents as the app serving the wrong thing with nothing in
    # the logs.
    test "a bare alias duplicating the primary domain is rejected", %{
      tenant: tenant,
      template: template
    } do
      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id,
          domain: "app.example.com",
          routed_port: 8000,
          additional_domains: [%{"host" => "app.example.com", "port" => 9999}]
        })

      refute changeset.valid?

      assert Enum.any?(
               errors_on(changeset).additional_domains,
               &(&1 =~ "already this deployment's domain")
             )
    end

    test "the duplicate check compares normalized hosts", %{tenant: tenant, template: template} do
      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id,
          domain: "app.example.com",
          additional_domains: [%{"host" => "APP.Example.com."}]
        })

      refute changeset.valid?
    end

    # A path-scoped duplicate gets a router name including the path, so it IS a distinct
    # router -- the same shape an extra path route takes. It stays allowed.
    test "a path-scoped duplicate of the primary domain is allowed", %{
      tenant: tenant,
      template: template
    } do
      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id,
          domain: "matrix.example.com",
          additional_domains: [%{"host" => "matrix.example.com", "path_prefix" => "/api"}]
        })

      assert changeset.valid?
    end
  end

  describe "changeset/2 status inclusion" do
    test "accepts every valid status" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      for status <- [:pending, :deploying, :running, :failed, :stopped, :removing] do
        changeset =
          Deployment.changeset(%Deployment{}, %{
            tenant_id: tenant.id,
            app_template_id: template.id,
            status: status
          })

        assert changeset.valid?, "expected #{status} to be valid"
      end
    end

    test "rejects an unknown status at cast time (Ecto.Enum)" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id,
          status: :bogus
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end
  end

  describe "changeset/2 constraints (via Repo)" do
    # NOTE: changeset/2 declares `unique_constraint([:tenant_id, :app_template_id])`,
    # but the backing DB index was dropped in migration 20260224004500
    # (`drop_if_exists unique_index(:deployments, [:tenant_id, :app_template_id])`).
    # With no index present the constraint never fires, so a duplicate currently
    # inserts successfully. This test pins that *actual* behavior; if the index is
    # ever restored, this is the test to flip to assert the "has already been taken"
    # error instead.
    test "duplicate [:tenant_id, :app_template_id] currently inserts (no backing index)" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      attrs = %{tenant_id: tenant.id, app_template_id: template.id}

      assert {:ok, _} = %Deployment{} |> Deployment.changeset(attrs) |> Repo.insert()
      assert {:ok, _} = %Deployment{} |> Deployment.changeset(attrs) |> Repo.insert()
    end

    test "same template under a different tenant is allowed" do
      template = insert(:app_template)
      t1 = insert(:tenant)
      t2 = insert(:tenant)

      assert {:ok, _} =
               %Deployment{}
               |> Deployment.changeset(%{tenant_id: t1.id, app_template_id: template.id})
               |> Repo.insert()

      assert {:ok, _} =
               %Deployment{}
               |> Deployment.changeset(%{tenant_id: t2.id, app_template_id: template.id})
               |> Repo.insert()
    end

    test "foreign_key_constraint on tenant_id" do
      template = insert(:app_template)

      assert {:error, changeset} =
               %Deployment{}
               |> Deployment.changeset(%{tenant_id: 999_999_999, app_template_id: template.id})
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).tenant_id
    end

    test "foreign_key_constraint on app_template_id" do
      tenant = insert(:tenant)

      assert {:error, changeset} =
               %Deployment{}
               |> Deployment.changeset(%{tenant_id: tenant.id, app_template_id: 999_999_999})
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).app_template_id
    end
  end

  describe "status_changeset/3" do
    test "sets only the status when no opts are given" do
      deployment = insert(:deployment)

      changeset = Deployment.status_changeset(deployment, :running)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == :running
      refute Ecto.Changeset.changed?(changeset, :error_message)
      refute Ecto.Changeset.changed?(changeset, :external_id)
    end

    test "sets error_message via :error opt" do
      deployment = insert(:deployment)

      changeset = Deployment.status_changeset(deployment, :failed, error: "kaboom")

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :error_message) == "kaboom"
    end

    test "sets external_id via :external_id opt" do
      deployment = insert(:deployment)

      changeset = Deployment.status_changeset(deployment, :running, external_id: "ctr-42")

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :external_id) == "ctr-42"
    end

    test "sets both error and external_id together" do
      deployment = insert(:deployment)

      changeset =
        Deployment.status_changeset(deployment, :failed, error: "bad", external_id: "x1")

      assert Ecto.Changeset.get_change(changeset, :error_message) == "bad"
      assert Ecto.Changeset.get_change(changeset, :external_id) == "x1"
    end

    test "a nil :error opt is treated as not provided (falsy guard)" do
      deployment = insert(:deployment, error_message: "old")

      changeset = Deployment.status_changeset(deployment, :running, error: nil)

      refute Ecto.Changeset.changed?(changeset, :error_message)
    end

    test "a nil :external_id opt is treated as not provided (falsy guard)" do
      deployment = insert(:deployment, external_id: "old")

      changeset = Deployment.status_changeset(deployment, :running, external_id: nil)

      refute Ecto.Changeset.changed?(changeset, :external_id)
    end

    test "rejects an invalid status" do
      deployment = insert(:deployment)

      changeset = Deployment.status_changeset(deployment, :nope)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end

    test "persists the new status through the Repo" do
      deployment = insert(:deployment)

      assert {:ok, updated} =
               deployment
               |> Deployment.status_changeset(:running, external_id: "ctr-9")
               |> Repo.update()

      assert updated.status == :running
      assert updated.external_id == "ctr-9"
    end
  end

  describe "reconciled_changeset/1" do
    test "stamps last_reconciled_at to roughly now" do
      deployment = insert(:deployment)

      before = DateTime.utc_now()
      changeset = Deployment.reconciled_changeset(deployment)
      stamped = Ecto.Changeset.get_change(changeset, :last_reconciled_at)

      assert %DateTime{} = stamped
      assert DateTime.compare(stamped, DateTime.add(before, -2, :second)) in [:gt, :eq]
      assert DateTime.compare(stamped, DateTime.add(DateTime.utc_now(), 2, :second)) in [:lt, :eq]
    end

    test "persists via the Repo" do
      deployment = insert(:deployment)

      assert {:ok, updated} =
               deployment |> Deployment.reconciled_changeset() |> Repo.update()

      assert updated.last_reconciled_at != nil
    end
  end
end
