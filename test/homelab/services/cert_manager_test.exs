defmodule Homelab.Services.CertManagerTest do
  use Homelab.DataCase, async: false

  import ExUnit.CaptureLog
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

      log =
        capture_log(fn ->
          CertManager.check_now()
          Process.sleep(200)
        end)

      assert log =~ "Failed to renew TLS for failing.homelab.local: :acme_challenge_failed"

      status = CertManager.status()
      assert status.renewed_count == 0

      updated_domain = Homelab.Repo.get!(Homelab.Networking.Domain, domain.id)
      assert updated_domain.tls_status == :failed
    end
  end

  describe "TLS enforcement latch" do
    setup do
      previous = Application.get_env(:homelab, :tls_probe_result, :healthy)
      on_exit(fn -> Application.put_env(:homelab, :tls_probe_result, previous) end)
      :ok
    end

    test "stays off while the domain serves Traefik's self-signed default" do
      Application.put_env(:homelab, :tls_probe_result, :self_signed)

      pid = start_supervised!({CertManager, enabled: false})
      send(pid, :check_certs)
      _ = :sys.get_state(pid)

      refute Homelab.Infrastructure.tls_enforced?()
    end

    # A handshake that cannot be completed is the ordinary state during propagation —
    # nothing is listening on 443 for a name that does not resolve yet.
    test "stays off when the certificate cannot be read at all" do
      Application.put_env(:homelab, :tls_probe_result, {:error, :timeout})

      pid = start_supervised!({CertManager, enabled: false})
      send(pid, :check_certs)
      _ = :sys.get_state(pid)

      refute Homelab.Infrastructure.tls_enforced?()
    end

    test "latches on once a real certificate is served" do
      Application.put_env(:homelab, :tls_probe_result, :healthy)

      pid = start_supervised!({CertManager, enabled: false})
      send(pid, :check_certs)
      _ = :sys.get_state(pid)

      assert Homelab.Infrastructure.tls_enforced?()
    end

    # The point of the latch: a cert that breaks later must raise alarms, never quietly
    # put the control plane back on plain HTTP for whoever is on the network.
    test "a later failure does not clear an already-set latch" do
      Application.put_env(:homelab, :tls_probe_result, :healthy)
      pid = start_supervised!({CertManager, enabled: false})
      send(pid, :check_certs)
      _ = :sys.get_state(pid)
      assert Homelab.Infrastructure.tls_enforced?()

      Application.put_env(:homelab, :tls_probe_result, :self_signed)
      send(pid, :check_certs)
      _ = :sys.get_state(pid)

      assert Homelab.Infrastructure.tls_enforced?()
    end
  end

  describe "handle_info :check_certs with no gateway" do
    test "does not crash when gateway is nil" do
      pid = start_supervised!({CertManager, enabled: false})
      send(pid, :check_certs)
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  describe "status/0" do
    test "returns expected map shape" do
      start_supervised!({CertManager, enabled: false})
      status = CertManager.status()

      assert is_map(status)
      assert Map.has_key?(status, :last_check_at)
      assert Map.has_key?(status, :renewed_count)
      assert Map.has_key?(status, :interval)
      assert Map.has_key?(status, :enabled)
      assert status.enabled == false
    end
  end
end
