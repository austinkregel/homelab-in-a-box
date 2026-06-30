defmodule Homelab.Crypto do
  @moduledoc """
  Symmetric encryption for secrets stored at rest (system settings, per-deployment
  credentials, …).

  Uses AES-256-GCM with a random IV per message, keyed off the endpoint's
  `secret_key_base`. The encoded payload is `Base.encode64(iv <> tag <> ciphertext)`.
  """

  @doc "Encrypts `plaintext`, returning a Base64 `iv <> tag <> ciphertext` string."
  def encrypt(plaintext) when is_binary(plaintext) do
    secret = encryption_key()
    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, plaintext, "", true)

    Base.encode64(iv <> tag <> ciphertext)
  end

  @doc "Decrypts a value produced by `encrypt/1`."
  def decrypt(encoded) when is_binary(encoded) do
    secret = encryption_key()
    decoded = Base.decode64!(encoded)
    <<iv::binary-16, tag::binary-16, ciphertext::binary>> = decoded
    :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, ciphertext, "", tag, false)
  end

  defp encryption_key do
    base =
      Application.get_env(:homelab, HomelabWeb.Endpoint)[:secret_key_base] ||
        raise """
        secret_key_base is not configured, so stored secrets cannot be \
        encrypted or decrypted. Set SECRET_KEY_BASE (production) or ensure the \
        endpoint config provides :secret_key_base.\
        """

    :crypto.hash(:sha256, base)
  end
end
