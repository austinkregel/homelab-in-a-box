defmodule Homelab.Networking.TlsObserverTest do
  # async: false -- the probe runs inside a Task, which does not inherit the caller's
  # process dictionary, so the staged result is read from the application env.
  use Homelab.DataCase, async: false

  import ExUnit.CaptureLog
  import Homelab.Factory

  alias Homelab.Networking.{Domain, TlsObserver}

  setup do
    previous = Application.get_env(:homelab, :tls_probe_result, :healthy)
    on_exit(fn -> Application.put_env(:homelab, :tls_probe_result, previous) end)
    :ok
  end

  defp reload(domain), do: Homelab.Repo.get!(Domain, domain.id)

  describe "observe_all/0" do
    test "records which name on the certificate covers the domain" do
      domain = insert(:domain, fqdn: "grafana.homelab.local", tls_status: :pending)

      Application.put_env(:homelab, :tls_probe_result, :wildcard)

      assert %{"grafana.homelab.local" => {:ok, _}} = TlsObserver.observe_all()

      reloaded = reload(domain)
      assert reloaded.tls_observed_status == :valid
      # The answer to "why is a domain nobody requested a certificate for served over
      # TLS", which is the whole reason this column exists.
      assert reloaded.tls_matched_name == "*.homelab.local"
      assert reloaded.tls_issuer == "Let's Encrypt R3"
      assert reloaded.tls_checked_at
    end

    test "records Traefik's default certificate as what it is" do
      domain = insert(:domain, fqdn: "apex.example.org", tls_status: :pending)

      Application.put_env(:homelab, :tls_probe_result, :self_signed)

      TlsObserver.observe_all()

      reloaded = reload(domain)
      assert reloaded.tls_observed_status == :self_signed
      assert reloaded.tls_matched_name == nil
    end

    # A handshake that cannot be completed is an observation, and a more useful one than
    # leaving the column nil: nothing is answering on :443 for this name.
    test "records a failed handshake as unreachable" do
      domain = insert(:domain, fqdn: "gone.example.org", tls_status: :pending)

      Application.put_env(:homelab, :tls_probe_result, {:error, {:handshake_failed, :nxdomain}})

      TlsObserver.observe_all()

      assert reload(domain).tls_observed_status == :unreachable
    end

    # `tls_status` is the lifecycle CertManager intends; this writes only what was seen.
    # Collapsing the two would make "serving the default cert, ACME still needs to try"
    # indistinguishable from "renewal errored".
    test "leaves the lifecycle column alone" do
      domain =
        insert(:domain,
          fqdn: "pending.example.org",
          tls_status: :pending,
          tls_expires_at: nil
        )

      Application.put_env(:homelab, :tls_probe_result, :self_signed)

      TlsObserver.observe_all()

      reloaded = reload(domain)
      assert reloaded.tls_status == :pending
      assert reloaded.tls_expires_at == nil
    end

    test "one unreadable certificate does not stop the pass" do
      readable = insert(:domain, fqdn: "fine.example.org", tls_status: :pending)
      unreadable = insert(:domain, fqdn: "broken.example.org", tls_status: :pending)

      Application.put_env(:homelab, :tls_probe_result, %{"broken.example.org" => :raise})

      log = capture_log(fn -> TlsObserver.observe_all() end)

      assert log =~ "broken.example.org served an unreadable certificate"
      assert reload(unreadable).tls_observed_status == :unreachable
      # The point: the other domain was still observed.
      assert reload(readable).tls_observed_status == :valid
    end

    test "overwrites an earlier observation" do
      domain =
        insert(:domain,
          fqdn: "changed.example.org",
          tls_status: :active,
          tls_observed_status: :valid,
          tls_matched_name: "changed.example.org",
          tls_checked_at:
            DateTime.utc_now() |> DateTime.add(-7, :day) |> DateTime.truncate(:second)
        )

      before = reload(domain).tls_checked_at
      Application.put_env(:homelab, :tls_probe_result, :self_signed)

      TlsObserver.observe_all()

      reloaded = reload(domain)
      assert reloaded.tls_observed_status == :self_signed
      assert reloaded.tls_matched_name == nil
      assert DateTime.compare(reloaded.tls_checked_at, before) == :gt
    end
  end

  describe "observe_fqdns/1" do
    test "observes only the names asked for" do
      asked = insert(:domain, fqdn: "asked.example.org", tls_status: :pending)
      other = insert(:domain, fqdn: "other.example.org", tls_status: :pending)

      TlsObserver.observe_fqdns(["asked.example.org"])

      assert reload(asked).tls_observed_status == :valid
      assert reload(other).tls_observed_status == nil
    end

    # The Domains page knows fqdns, and some of them belong to deployments with no
    # `domains` row -- there is nothing to record against those, and asking must not
    # raise.
    test "skips a name with no domain row" do
      assert TlsObserver.observe_fqdns(["nothing-here.example.org"]) == %{}
    end

    test "observes a name only once when asked twice" do
      domain = insert(:domain, fqdn: "dup.example.org", tls_status: :pending)

      assert map_size(TlsObserver.observe_fqdns(["dup.example.org", "dup.example.org"])) == 1
      assert reload(domain).tls_observed_status == :valid
    end
  end
end
