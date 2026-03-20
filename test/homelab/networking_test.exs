defmodule Homelab.NetworkingTest do
  use Homelab.DataCase, async: true

  alias Homelab.Networking
  alias Homelab.Networking.Domain
  import Homelab.Factory

  describe "list_domains/0" do
    test "returns all domains with preloaded deployment" do
      deployment = insert(:deployment)
      insert(:domain, deployment: deployment)

      domains = Networking.list_domains()
      assert length(domains) == 1
      assert hd(domains).deployment != nil
    end
  end

  describe "list_domains_for_deployment/1" do
    test "returns domains for a specific deployment" do
      deployment = insert(:deployment)
      other_deployment = insert(:deployment)
      insert(:domain, deployment: deployment)
      insert(:domain, deployment: other_deployment)

      domains = Networking.list_domains_for_deployment(deployment.id)
      assert length(domains) == 1
      assert hd(domains).deployment_id == deployment.id
    end
  end

  describe "list_expiring_tls/1" do
    test "returns domains with TLS expiring before given date" do
      deployment = insert(:deployment)
      expiring_date = DateTime.utc_now() |> DateTime.add(5, :day) |> DateTime.truncate(:second)
      far_date = DateTime.utc_now() |> DateTime.add(90, :day) |> DateTime.truncate(:second)
      check_before = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      insert(:domain,
        deployment: deployment,
        tls_status: :active,
        tls_expires_at: expiring_date,
        fqdn: "expiring.homelab.local"
      )

      insert(:domain,
        deployment: deployment,
        tls_status: :active,
        tls_expires_at: far_date,
        fqdn: "not-expiring.homelab.local"
      )

      expiring = Networking.list_expiring_tls(check_before)
      assert length(expiring) == 1
      assert hd(expiring).fqdn == "expiring.homelab.local"
    end
  end

  describe "get_domain/1" do
    test "returns domain by id" do
      deployment = insert(:deployment)
      domain = insert(:domain, deployment: deployment)
      assert {:ok, found} = Networking.get_domain(domain.id)
      assert found.id == domain.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Networking.get_domain(999)
    end
  end

  describe "get_domain_by_fqdn/1" do
    test "returns domain by fqdn" do
      deployment = insert(:deployment)
      insert(:domain, deployment: deployment, fqdn: "app.homelab.local")

      assert {:ok, found} = Networking.get_domain_by_fqdn("app.homelab.local")
      assert found.fqdn == "app.homelab.local"
    end
  end

  describe "create_domain/1" do
    test "creates a domain with valid attrs" do
      deployment = insert(:deployment)

      attrs = %{
        fqdn: "nextcloud.friends.homelab.local",
        deployment_id: deployment.id,
        exposure_mode: :sso_protected
      }

      assert {:ok, %Domain{} = domain} = Networking.create_domain(attrs)
      assert domain.fqdn == "nextcloud.friends.homelab.local"
      assert domain.tls_status == :pending
    end

    test "returns error with invalid fqdn" do
      deployment = insert(:deployment)
      attrs = %{fqdn: "INVALID DOMAIN!", deployment_id: deployment.id}
      assert {:error, changeset} = Networking.create_domain(attrs)
      assert errors_on(changeset).fqdn != []
    end

    test "enforces unique fqdn constraint" do
      deployment = insert(:deployment)
      insert(:domain, deployment: deployment, fqdn: "taken.homelab.local")

      attrs = %{fqdn: "taken.homelab.local", deployment_id: deployment.id}
      assert {:error, changeset} = Networking.create_domain(attrs)
      assert errors_on(changeset).fqdn != []
    end
  end

  describe "update_domain/2" do
    test "updates domain attributes" do
      deployment = insert(:deployment)
      domain = insert(:domain, deployment: deployment)

      assert {:ok, updated} = Networking.update_domain(domain, %{tls_status: :active})
      assert updated.tls_status == :active
    end
  end

  describe "delete_domain/1" do
    test "deletes a domain" do
      deployment = insert(:deployment)
      domain = insert(:domain, deployment: deployment)
      assert {:ok, _} = Networking.delete_domain(domain)
      assert {:error, :not_found} = Networking.get_domain(domain.id)
    end
  end
end
