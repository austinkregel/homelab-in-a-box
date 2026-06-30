defmodule Homelab.Schemas.DomainChangesetTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Networking.Domain

  defp valid_attrs(deployment) do
    %{fqdn: "app.example.com", deployment_id: deployment.id}
  end

  describe "changeset/2 required fields" do
    setup do
      %{deployment: insert(:deployment)}
    end

    test "is valid with fqdn and deployment_id", %{deployment: deployment} do
      assert Domain.changeset(%Domain{}, valid_attrs(deployment)).valid?
    end

    test "requires fqdn and deployment_id" do
      cs = Domain.changeset(%Domain{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.fqdn
      assert "can't be blank" in errors.deployment_id
    end

    test "requires deployment_id when fqdn present" do
      cs = Domain.changeset(%Domain{}, %{fqdn: "x.example.com"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).deployment_id
    end
  end

  describe "changeset/2 fqdn format" do
    setup do
      %{deployment: insert(:deployment)}
    end

    test "accepts a typical fqdn", %{deployment: deployment} do
      assert Domain.changeset(%Domain{}, valid_attrs(deployment)).valid?
    end

    test "accepts a subdomain with hyphens and digits", %{deployment: deployment} do
      attrs = %{valid_attrs(deployment) | fqdn: "my-app-1.sub.example.com"}
      assert Domain.changeset(%Domain{}, attrs).valid?
    end

    test "rejects uppercase characters", %{deployment: deployment} do
      attrs = %{valid_attrs(deployment) | fqdn: "App.Example.com"}
      cs = Domain.changeset(%Domain{}, attrs)
      refute cs.valid?
      assert "must be a valid fully qualified domain name" in errors_on(cs).fqdn
    end

    test "rejects leading hyphen", %{deployment: deployment} do
      attrs = %{valid_attrs(deployment) | fqdn: "-app.example.com"}
      cs = Domain.changeset(%Domain{}, attrs)
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :fqdn)
    end

    test "rejects trailing hyphen", %{deployment: deployment} do
      attrs = %{valid_attrs(deployment) | fqdn: "app.example.com-"}
      cs = Domain.changeset(%Domain{}, attrs)
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :fqdn)
    end

    test "rejects a single-character fqdn (regex requires middle segment)", %{
      deployment: deployment
    } do
      attrs = %{valid_attrs(deployment) | fqdn: "a"}
      cs = Domain.changeset(%Domain{}, attrs)
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :fqdn)
    end

    test "rejects fqdn with illegal characters", %{deployment: deployment} do
      attrs = %{valid_attrs(deployment) | fqdn: "app_underscore.example.com"}
      cs = Domain.changeset(%Domain{}, attrs)
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :fqdn)
    end
  end

  describe "changeset/2 enum fields" do
    setup do
      %{deployment: insert(:deployment)}
    end

    test "accepts valid exposure_mode values", %{deployment: deployment} do
      for mode <- [:private, :sso_protected, :public] do
        attrs = Map.put(valid_attrs(deployment), :exposure_mode, mode)
        assert Domain.changeset(%Domain{}, attrs).valid?
      end
    end

    test "rejects invalid exposure_mode", %{deployment: deployment} do
      attrs = Map.put(valid_attrs(deployment), :exposure_mode, :service)
      cs = Domain.changeset(%Domain{}, attrs)
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :exposure_mode)
    end

    test "accepts valid tls_status values", %{deployment: deployment} do
      for status <- [:pending, :active, :expired, :failed] do
        attrs = Map.put(valid_attrs(deployment), :tls_status, status)
        assert Domain.changeset(%Domain{}, attrs).valid?
      end
    end

    test "rejects invalid tls_status", %{deployment: deployment} do
      attrs = Map.put(valid_attrs(deployment), :tls_status, :revoked)
      cs = Domain.changeset(%Domain{}, attrs)
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :tls_status)
    end
  end

  describe "constraints via Repo" do
    test "rejects non-existent deployment_id (foreign key)" do
      {:error, cs} =
        %Domain{}
        |> Domain.changeset(%{fqdn: "fk.example.com", deployment_id: -1})
        |> Repo.insert()

      assert "does not exist" in errors_on(cs).deployment_id
    end

    test "rejects duplicate fqdn (unique)" do
      deployment = insert(:deployment)
      insert(:domain, fqdn: "dup.example.com", deployment: deployment)

      other = insert(:deployment)

      {:error, cs} =
        %Domain{}
        |> Domain.changeset(%{fqdn: "dup.example.com", deployment_id: other.id})
        |> Repo.insert()

      assert "has already been taken" in errors_on(cs).fqdn
    end

    test "inserts with a valid deployment and unique fqdn" do
      deployment = insert(:deployment)

      assert {:ok, _} =
               %Domain{}
               |> Domain.changeset(%{fqdn: "ok.example.com", deployment_id: deployment.id})
               |> Repo.insert()
    end
  end
end
