defmodule Homelab.Storage.SecretsTest do
  use Homelab.DataCase, async: false

  alias Homelab.Storage.Secrets

  describe "settings backend (fallback path)" do
    setup do
      # The stub always uses :settings backend until Vault is wired.
      Application.put_env(:homelab, :secrets_backend, :settings)
      :ok
    end

    test "write + read round-trips a secret value" do
      ref = "secret/homelab/test/foo-#{System.unique_integer([:positive])}"
      assert :ok = Secrets.write(ref, "hunter2")
      assert {:ok, "hunter2"} = Secrets.read(ref)
    end

    test "read returns :not_found for missing refs" do
      ref = "secret/homelab/test/missing-#{System.unique_integer([:positive])}"
      assert {:error, :not_found} = Secrets.read(ref)
    end

    test "read! raises on missing ref" do
      ref = "secret/homelab/test/missing-#{System.unique_integer([:positive])}"

      assert_raise RuntimeError, ~r/Secret .* unavailable/, fn ->
        Secrets.read!(ref)
      end
    end

    test "read_or_generate writes a new value when ref is empty and returns it" do
      ref = "secret/homelab/test/gen-#{System.unique_integer([:positive])}"
      assert {:ok, value} = Secrets.read_or_generate(ref, fn -> "auto-generated" end)
      assert value == "auto-generated"
      assert {:ok, "auto-generated"} = Secrets.read(ref)
    end

    test "read_or_generate is idempotent (does not re-roll on subsequent calls)" do
      ref = "secret/homelab/test/idempotent-#{System.unique_integer([:positive])}"
      {:ok, v1} = Secrets.read_or_generate(ref, &Secrets.random_password/0)
      {:ok, v2} = Secrets.read_or_generate(ref, &Secrets.random_password/0)
      assert v1 == v2
    end
  end

  describe "vault backend (stub returns :vault_unavailable until wired)" do
    setup do
      Application.put_env(:homelab, :secrets_backend, :vault)
      on_exit(fn -> Application.put_env(:homelab, :secrets_backend, :settings) end)
      :ok
    end

    test "read returns :vault_unavailable" do
      assert {:error, :vault_unavailable} = Secrets.read("secret/homelab/whatever")
    end

    test "write returns :vault_unavailable" do
      assert {:error, :vault_unavailable} = Secrets.write("secret/homelab/whatever", "x")
    end
  end

  describe "generators" do
    test "random_password returns a 32-byte base64-url string" do
      pw = Secrets.random_password()
      assert is_binary(pw)
      assert byte_size(pw) >= 32
      assert pw =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "random_raw_key returns 32 random bytes" do
      key = Secrets.random_raw_key()
      assert byte_size(key) == 32
    end

    test "consecutive generator calls produce different values" do
      refute Secrets.random_password() == Secrets.random_password()
      refute Secrets.random_raw_key() == Secrets.random_raw_key()
    end
  end
end
