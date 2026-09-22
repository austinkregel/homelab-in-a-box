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

    test "records the expiry the domain is actually serving, not one 90 days out" do
      deployment = insert(:deployment)
      expiring_date = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)

      domain =
        insert(:domain,
          deployment: deployment,
          tls_status: :active,
          tls_expires_at: expiring_date,
          fqdn: "expiring.homelab.local"
        )

      Homelab.Mocks.Gateway
      |> expect(:provision_tls, fn "expiring.homelab.local" -> {:ok, %{cert: "new_cert"}} end)

      start_supervised!({CertManager, enabled: false, interval: :timer.hours(1)})
      CertManager.check_now()
      Process.sleep(200)

      # The stub serves a certificate 60 days out. The old code wrote 90 regardless of
      # what was being served, including when nothing had been reissued at all.
      reloaded = Homelab.Repo.get!(Homelab.Networking.Domain, domain.id)
      assert DateTime.diff(reloaded.tls_expires_at, DateTime.utc_now(), :day) in 59..60
    end

    test "does not count a renewal when the served certificate did not change" do
      deployment = insert(:deployment)
      previous = Application.get_env(:homelab, :tls_probe_result, :healthy)
      on_exit(fn -> Application.put_env(:homelab, :tls_probe_result, previous) end)

      served = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)

      insert(:domain,
        deployment: deployment,
        tls_status: :active,
        tls_expires_at: served,
        fqdn: "stuck.homelab.local"
      )

      # The handshake still shows the certificate we already had -- ACME did not issue.
      Application.put_env(
        :homelab,
        :tls_probe_result,
        {:ok,
         %{Homelab.Networking.TlsProbeStub.healthy("stuck.homelab.local") | not_after: served}}
      )

      Homelab.Mocks.Gateway
      |> expect(:provision_tls, fn "stuck.homelab.local" -> {:ok, %{cert: "same"}} end)

      start_supervised!({CertManager, enabled: false, interval: :timer.hours(1)})
      CertManager.check_now()
      Process.sleep(200)

      # Reported as renewed before, which took it out of the expiring window for two
      # months even though nothing had been reissued.
      assert CertManager.status().renewed_count == 0
    end
  end

  describe "pending domains" do
    setup do
      previous = Application.get_env(:homelab, :tls_probe_result, :healthy)
      on_exit(fn -> Application.put_env(:homelab, :tls_probe_result, previous) end)
      :ok
    end

    # The case the Domains page was reporting wrong: a subdomain under a wildcard never
    # needs a certificate of its own, and `provision_tls/1` has no router to answer for
    # it, so the row sat at :pending forever while being served perfectly well.
    test "records a domain already covered by a wildcard without provisioning" do
      deployment = insert(:deployment)

      domain =
        insert(:domain,
          deployment: deployment,
          tls_status: :pending,
          tls_expires_at: nil,
          fqdn: "grafana.homelab.local"
        )

      Application.put_env(:homelab, :tls_probe_result, :wildcard)

      # No `expect(:provision_tls, ...)`. `verify_on_exit!` fails the test if the
      # gateway is asked for a certificate the domain already has.
      start_supervised!({CertManager, enabled: false, interval: :timer.hours(1)})
      CertManager.check_now()
      Process.sleep(200)

      reloaded = Homelab.Repo.get!(Homelab.Networking.Domain, domain.id)
      assert reloaded.tls_status == :active
      assert DateTime.diff(reloaded.tls_expires_at, DateTime.utc_now(), :day) in 59..60
    end

    test "asks the gateway to provision a domain serving the default certificate" do
      deployment = insert(:deployment)

      domain =
        insert(:domain,
          deployment: deployment,
          tls_status: :pending,
          tls_expires_at: nil,
          fqdn: "new.homelab.local"
        )

      Application.put_env(:homelab, :tls_probe_result, :self_signed)

      Homelab.Mocks.Gateway
      |> expect(:provision_tls, fn "new.homelab.local" -> {:ok, %{status: :active}} end)

      start_supervised!({CertManager, enabled: false, interval: :timer.hours(1)})
      CertManager.check_now()
      Process.sleep(200)

      # Stays pending. `provision_tls/1` answering :active only means a router exists --
      # taking that as proof of a certificate is what marked self-signed domains active.
      reloaded = Homelab.Repo.get!(Homelab.Networking.Domain, domain.id)
      assert reloaded.tls_status == :pending
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
