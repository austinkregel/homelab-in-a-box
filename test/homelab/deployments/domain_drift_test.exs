defmodule Homelab.Deployments.DomainDriftTest do
  @moduledoc """
  A deployment's domain is editable, but the `Domain` row derived from it was written
  once at first deploy and never revisited.
  """
  use Homelab.DataCase, async: false

  import Homelab.Factory
  import Mox

  alias Homelab.{Deployments, Networking}

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Homelab.Mocks.Orchestrator
    |> stub(:deploy, fn _spec -> {:ok, "svc_1"} end)
    |> stub(:undeploy, fn _id -> :ok end)
    |> stub(:stats, fn _id -> {:error, :not_found} end)
    |> stub(:get_service, fn _id -> {:error, :not_found} end)
    |> stub(:list_services, fn -> {:ok, []} end)

    Homelab.Mocks.DnsProvider
    |> stub(:list_records, fn _zone -> {:ok, []} end)
    |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:update_record, fn _zone, _id, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:delete_record, fn _zone, _id -> :ok end)

    template = insert(:app_template, exposure_mode: :sso_protected)
    deployment = insert(:deployment, app_template: template, domain: "old.example.com")

    %{deployment: deployment}
  end

  test "moving a deployment's domain retires the row for the old one", %{
    deployment: deployment
  } do
    Deployments.sync_domain_records(deployment)
    assert {:ok, _} = Networking.get_domain_by_fqdn("old.example.com")

    # Editing the domain is what every Settings save does; nothing used to re-derive
    # the Domain row afterwards.
    {:ok, _moved} = Deployments.update_deployment(deployment, %{domain: "new.example.com"})

    assert {:ok, current} = Networking.get_domain_by_fqdn("new.example.com")
    assert current.deployment_id == deployment.id

    # The old row carried TLS state and a DNS-zone link for a name this deployment is
    # no longer served at, and sat on the fqdn unique index forever.
    assert {:error, :not_found} = Networking.get_domain_by_fqdn("old.example.com")
    assert [only] = Networking.list_domains_for_deployment(deployment.id)
    assert only.fqdn == "new.example.com"
  end

  test "clearing the domain retires every row the deployment held", %{deployment: deployment} do
    Deployments.sync_domain_records(deployment)
    assert {:ok, _} = Networking.get_domain_by_fqdn("old.example.com")

    {:ok, _} = Deployments.update_deployment(deployment, %{domain: nil})

    assert Networking.list_domains_for_deployment(deployment.id) == []
  end

  test "the domain row records the effective exposure, not the template's", %{
    deployment: deployment
  } do
    # This read app_template.exposure_mode and ignored the override, so a deployment
    # moved to :public kept a row claiming it was SSO-protected.
    Deployments.sync_domain_records(deployment)
    assert {:ok, before} = Networking.get_domain_by_fqdn("old.example.com")
    assert before.exposure_mode == :sso_protected

    {:ok, _opened} =
      Deployments.update_deployment(deployment, %{exposure_mode_override: "public"})

    assert {:ok, domain} = Networking.get_domain_by_fqdn("old.example.com")
    assert domain.exposure_mode == :public
  end
end
