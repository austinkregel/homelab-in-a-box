defmodule Homelab.Deployments.ReleaseSteps.VerifyPublicUrlTest do
  # async: false — the probes are injected through the application env, which is
  # process-global.
  use Homelab.DataCase, async: false

  import Homelab.Factory

  alias Homelab.Deployments.ReleaseSteps.VerifyPublicUrl
  alias Homelab.Networking.{TlsProbeStub, UrlProbeStub}

  setup do
    on_exit(fn ->
      Application.delete_env(:homelab, :url_probe_result)
      Application.delete_env(:homelab, :tls_probe_result)
    end)

    :ok
  end

  defp ctx(deployment), do: %{deployment: deployment, release: nil}
  defp step(handle \\ %{}), do: %Homelab.Deployments.ReleaseStep{resource_handle: handle}

  defp routed(attrs \\ []) do
    insert(
      :deployment,
      Keyword.merge([status: :running, external_id: "c1", domain: "app.example.test"], attrs)
    )
  end

  describe "when the app answers" do
    test "passes and records the URL and status" do
      deployment = routed()

      assert {:ok, handle} = VerifyPublicUrl.run(step(), ctx(deployment))

      assert handle["verified"] == true
      assert handle["url"] == "https://app.example.test/"
      assert handle["status"] == 200
    end

    # A 302 to the identity provider, a 404 from an app that serves nothing at `/`, a 500
    # from an app that is up and broken: all three prove DNS, TLS, the router and the
    # backend carried the request. Requiring 200 would fail correctly-deployed apps.
    test "any status the app produces counts as reachable" do
      deployment = routed()

      for status <- [302, 401, 404, 500] do
        Application.put_env(
          :homelab,
          :url_probe_result,
          {:ok, UrlProbeStub.answered("https://app.example.test/", status)}
        )

        assert {:ok, %{"verified" => true, "status" => ^status}} =
                 VerifyPublicUrl.run(step(), ctx(deployment))
      end
    end
  end

  describe "when it is not reachable" do
    # The failure this whole step exists to catch, and the one a naive probe reports as
    # success: a perfectly ordinary HTTP response, served by us, precisely because the
    # app is not answering.
    test "our own hold page is not mistaken for the app" do
      deployment = routed()
      Application.put_env(:homelab, :url_probe_result, :holding)

      assert {:error, {:url_unreachable, "app.example.test", {:holding, "updating"}}} =
               VerifyPublicUrl.run(step(), ctx(deployment))
    end

    test "a name that does not resolve reports the handshake, not the app" do
      deployment = routed()
      Application.put_env(:homelab, :tls_probe_result, {:error, {:handshake_failed, :nxdomain}})

      assert {:error, {:url_unreachable, _domain, {:tls_handshake_failed, _}}} =
               VerifyPublicUrl.run(step(), ctx(deployment))
    end

    # Traefik serves its built-in placeholder while ACME has not issued, which a browser
    # rejects outright. Reported as its own reason rather than as "the app did not
    # answer", because the app is fine and the certificate is the thing to look at.
    test "the Traefik default certificate is reported as a pending certificate" do
      deployment = routed()
      Application.put_env(:homelab, :tls_probe_result, {:ok, TlsProbeStub.self_signed()})

      assert {:error, {:url_unreachable, _domain, :certificate_pending}} =
               VerifyPublicUrl.run(step(), ctx(deployment))
    end
  end

  describe "targeting" do
    test "verifies the deployment named in the handle, not the release's own" do
      app = routed(domain: "app.example.test")
      child = routed(domain: "child.example.test")

      assert {:ok, handle} =
               VerifyPublicUrl.run(step(%{"deployment_id" => child.id}), ctx(app))

      assert handle["url"] == "https://child.example.test/"
    end

    # A race, not a misplan: `verify_steps/1` only plans this for a deployment holding a
    # name, so reaching here without one means the domain was cleared in between.
    test "a deployment with no domain has nothing to verify" do
      deployment = routed(domain: nil)

      assert {:ok, %{"verified" => false}} = VerifyPublicUrl.run(step(), ctx(deployment))
    end
  end
end
