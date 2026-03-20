defmodule Homelab.Services.CertManagerTest do
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Services.CertManager

  setup :set_mox_global
  setup :verify_on_exit!

  describe "init/1" do
    test "starts with default state" do
      start_supervised!({CertManager, enabled: false})
      status = CertManager.status()

      assert status.last_check_at == nil
      assert status.renewed_count == 0
    end
  end

  describe "certificate renewal" do
    test "renews expiring certificates" do
      deployment = insert(:deployment)
      expiring_date = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)

      insert(:domain,
        deployment: deployment,
        tls_status: :active,
        tls_expires_at: expiring_date,
        fqdn: "expiring.homelab.local"
      )

      Homelab.Mocks.Gateway
      |> expect(:provision_tls, fn "expiring.homelab.local" ->
        {:ok, %{cert: "new_cert", expires_at: DateTime.utc_now() |> DateTime.add(90, :day)}}
      end)

      start_supervised!({CertManager, enabled: false, interval: :timer.hours(1)})
      CertManager.check_now()
      Process.sleep(200)

      status = CertManager.status()
      assert status.renewed_count == 1
    end

    test "does not renew certificates far from expiry" do
      deployment = insert(:deployment)
      far_date = DateTime.utc_now() |> DateTime.add(60, :day) |> DateTime.truncate(:second)

      insert(:domain,
        deployment: deployment,
        tls_status: :active,
        tls_expires_at: far_date,
        fqdn: "not-expiring.homelab.local"
      )

      start_supervised!({CertManager, enabled: false, interval: :timer.hours(1)})
      CertManager.check_now()
      Process.sleep(200)

      status = CertManager.status()
      assert status.renewed_count == 0
    end

    test "handles renewal failure gracefully" do
      deployment = insert(:deployment)
      expiring_date = DateTime.utc_now() |> DateTime.add(5, :day) |> DateTime.truncate(:second)

      domain =
        insert(:domain,
          deployment: deployment,
          tls_status: :active,
          tls_expires_at: expiring_date,
          fqdn: "failing.homelab.local"
        )

      Homelab.Mocks.Gateway
      |> expect(:provision_tls, fn "failing.homelab.local" ->
        {:error, :acme_challenge_failed}
      end)

      start_supervised!({CertManager, enabled: false, interval: :timer.hours(1)})
      CertManager.check_now()
      Process.sleep(200)

      status = CertManager.status()
      assert status.renewed_count == 0

      updated_domain = Homelab.Repo.get!(Homelab.Networking.Domain, domain.id)
      assert updated_domain.tls_status == :failed
    end
  end
end
