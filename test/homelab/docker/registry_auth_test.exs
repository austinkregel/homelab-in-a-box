defmodule Homelab.Docker.RegistryAuthTest do
  # async: false — mutates the :homelab application env; the "no creds" case
  # falls through to Settings (DB), so we need a sandbox.
  use Homelab.DataCase, async: false

  alias Homelab.Docker.RegistryAuth

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

      decoded = encoded |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert decoded["username"] == "bob"
      assert decoded["password"] == "s3cret"
      assert decoded["serveraddress"] == "registry.example.com"
    end
  end

  describe "for_ref/1" do
    test "returns a header for images under the self-hosted registry prefix" do
      assert {"X-Registry-Auth", _} =
               RegistryAuth.for_ref("registry.example.com/homelab-built/app:1.0")
    end

    test "returns nil for public images" do
      assert RegistryAuth.for_ref("nginx:latest") == nil
      assert RegistryAuth.for_ref("ghcr.io/owner/app:1.0") == nil
    end

    test "returns nil when credentials are absent" do
      Application.delete_env(:homelab, :registry_credentials)
      assert RegistryAuth.for_ref("registry.example.com/homelab-built/app:1.0") == nil
    end
  end
end
