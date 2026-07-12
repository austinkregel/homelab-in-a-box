defmodule Homelab.CryptoTest do
  # async: false — the key-rotation test mutates the endpoint's secret_key_base.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Homelab.Crypto

  test "round-trips a value through encrypt/decrypt" do
    plaintext = "s3cr3t-p@ssw0rd"
    encoded = Crypto.encrypt(plaintext)

    assert is_binary(encoded)
    refute encoded == plaintext
    assert Crypto.decrypt(encoded) == plaintext
  end

  test "produces a different ciphertext each time (random IV)" do
    assert Crypto.encrypt("same") != Crypto.encrypt("same")
  end

  describe "decrypt/1 with the wrong key" do
    test "returns nil and logs, rather than the bare :error atom" do
      encoded = Crypto.encrypt("ghp_the_real_token")

      config = Application.get_env(:homelab, HomelabWeb.Endpoint)
      original = config[:secret_key_base]

      Application.put_env(
        :homelab,
        HomelabWeb.Endpoint,
        Keyword.put(config, :secret_key_base, String.duplicate("a-different-key", 8))
      )

      on_exit(fn ->
        Application.put_env(
          :homelab,
          HomelabWeb.Endpoint,
          Keyword.put(config, :secret_key_base, original)
        )
      end)

      log = capture_log(fn -> assert Crypto.decrypt(encoded) == nil end)
      assert log =~ "could not be decrypted"

      # :crypto hands back the bare atom :error on GCM failure. Every caller expects
      # a binary, so leaking it would JSON-encode as the string "error" and get used
      # as a registry *password* — a key mismatch surfacing as an inexplicable 401.
      refute Crypto.decrypt(encoded) == :error
    end
  end
end
