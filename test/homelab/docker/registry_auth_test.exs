defmodule Homelab.Docker.RegistryAuthTest do
  # async: false — mutates the :homelab application env; the "no creds" case
  # falls through to Settings (DB), so we need a sandbox.
  use Homelab.DataCase, async: false

  alias Homelab.Docker.RegistryAuth
  alias Homelab.Settings

  setup do
    prev_domain = Application.get_env(:homelab, :base_domain)
    prev_creds = Application.get_env(:homelab, :registry_credentials)
    Application.put_env(:homelab, :base_domain, "example.com")
    Application.put_env(:homelab, :registry_credentials, {"bob", "s3cret"})

    on_exit(fn ->
      restore(:base_domain, prev_domain)
      restore(:registry_credentials, prev_creds)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:homelab, key)
  defp restore(key, val), do: Application.put_env(:homelab, key, val)

  describe "header/1" do
    test "encodes an AuthConfig as base64url JSON" do
      {"X-Registry-Auth", encoded} =
        RegistryAuth.header(%{
          username: "bob",
          password: "s3cret",
          serveraddress: "registry.example.com"
        })

      decoded = encoded |> Base.url_decode64!() |> Jason.decode!()
      assert decoded["username"] == "bob"
      assert decoded["password"] == "s3cret"
      assert decoded["serveraddress"] == "registry.example.com"
    end

    test "the base64 is PADDED, as the daemon's decoder requires" do
      {"X-Registry-Auth", encoded} =
        RegistryAuth.header(%{
          username: "bob",
          password: "s3cret",
          serveraddress: "registry.example.com"
        })

      # The daemon decodes with Go's base64.URLEncoding (padded). An unpadded value
      # does not error — it fails to decode and the daemon silently falls back to an
      # ANONYMOUS pull, so a private image 401s however good the credentials were.
      # Decoding with padding: true (strict) must therefore succeed.
      assert {:ok, _} = Base.url_decode64(encoded)
      assert rem(String.length(encoded), 4) == 0
    end
  end

  describe "for_ref/1" do
    test "returns a header for images under the self-hosted registry prefix" do
      assert {"X-Registry-Auth", _} =
               RegistryAuth.for_ref("registry.example.com/homelab-built/app:1.0")
    end

    test "returns nil for public images" do
      assert RegistryAuth.for_ref("nginx:latest") == nil
      # No ghcr_token configured here, so GHCR contributes no credentials either.
      assert RegistryAuth.for_ref("ghcr.io/owner/app:1.0") == nil
    end

    test "returns nil when credentials are absent" do
      Application.delete_env(:homelab, :registry_credentials)
      assert RegistryAuth.for_ref("registry.example.com/homelab-built/app:1.0") == nil
    end
  end

  # A configured registry driver advertising :pull_auth (GHCR) must also hand its
  # credentials to the daemon. This was implemented but never called: a private GHCR
  # package was pulled anonymously and 401'd.
  describe "for_ref/1 — third-party registries (GHCR)" do
    # config/test.exs narrows :registries to DockerHub; production carries all three.
    setup do
      prev = Application.get_env(:homelab, :registries)

      Application.put_env(:homelab, :registries, [
        Homelab.Registries.DockerHub,
        Homelab.Registries.GHCR
      ])

      on_exit(fn -> restore(:registries, prev) end)
      :ok
    end

    defp decode({"X-Registry-Auth", encoded}) do
      encoded |> Base.url_decode64!() |> Jason.decode!()
    end

    test "authenticates a private GHCR image with the configured token" do
      Settings.set("ghcr_token", "ghp_secret", encrypt: true)

      auth = RegistryAuth.for_ref("ghcr.io/austinkregel/aut.hair:latest")
      refute is_nil(auth), "a private GHCR image must be pulled WITH credentials"

      assert %{
               "username" => "token",
               "password" => "ghp_secret",
               "serveraddress" => "ghcr.io"
             } = decode(auth)
    end

    test "uses the configured GitHub username when one is set" do
      Settings.set("ghcr_token", "ghp_secret", encrypt: true)
      Settings.set("ghcr_username", "austinkregel")

      assert %{"username" => "austinkregel", "password" => "ghp_secret"} =
               "ghcr.io/austinkregel/aut.hair:latest" |> RegistryAuth.for_ref() |> decode()
    end

    test "does not leak the GHCR token onto refs that are not GHCR's" do
      Settings.set("ghcr_token", "ghp_secret", encrypt: true)

      assert RegistryAuth.for_ref("nginx:latest") == nil
      # A lookalike host that merely starts with the same characters is not ghcr.io.
      assert RegistryAuth.for_ref("ghcr.io.evil.example/owner/app:1.0") == nil
    end

    test "the self-hosted registry still wins for its own refs" do
      Settings.set("ghcr_token", "ghp_secret", encrypt: true)

      assert %{"username" => "bob", "serveraddress" => "registry.example.com"} =
               "registry.example.com/homelab-built/app:1.0" |> RegistryAuth.for_ref() |> decode()
    end
  end
end
