defmodule Homelab.CryptoTest do
  use ExUnit.Case, async: true

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
end
