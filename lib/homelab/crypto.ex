defmodule Homelab.Crypto do
  @moduledoc """
  Symmetric encryption for secrets stored at rest (system settings, per-deployment
  credentials, …).

  Uses AES-256-GCM with a random IV per message, keyed off the endpoint's
  `secret_key_base`. The encoded payload is `Base.encode64(iv <> tag <> ciphertext)`.
  """

  require Logger

  @doc "Encrypts `plaintext`, returning a Base64 `iv <> tag <> ciphertext` string."
  def encrypt(plaintext) when is_binary(plaintext) do
    secret = encryption_key()
    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, plaintext, "", true)

    Base.encode64(iv <> tag <> ciphertext)
  end

  @doc """
  Decrypts a value produced by `encrypt/1`, or returns `nil` if it cannot be
  decrypted with the current key.

  GCM verification fails — and `:crypto` returns the bare atom `:error` rather than
  raising — whenever `secret_key_base` is not the one the value was encrypted with,
  which happens if the persisted secret is lost (a recreated `homelab-iab-secrets`
  volume) or SECRET_KEY_BASE is set to something new. Returning that atom to callers
  is worse than useless: every caller here expects a binary, so `:error` would sail
  on to be JSON-encoded as the string "error" and used as a *password*, turning a
  key mismatch into an unexplainable 401 from a registry. Fail loudly, return nil.
  """
  def decrypt(encoded) when is_binary(encoded) do
    secret = encryption_key()
    decoded = Base.decode64!(encoded)
    <<iv::binary-16, tag::binary-16, ciphertext::binary>> = decoded

    case :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) ->
        plaintext

      :error ->
        Logger.error("""
        [Crypto] A stored secret could not be decrypted with the current \
        secret_key_base. It was encrypted with a different key — most likely the \
        `homelab-iab-secrets` volume was recreated, or SECRET_KEY_BASE changed. \
        Secrets saved before that point are unrecoverable and must be re-entered \
        (Settings → Registries / Identity).\
        """)

        nil
    end
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
