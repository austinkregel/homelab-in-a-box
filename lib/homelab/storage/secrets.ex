defmodule Homelab.Storage.Secrets.VaultUnavailableError do
  defexception [:message]
end

defmodule Homelab.Storage.Secrets do
  @moduledoc """
  Canonical keystore facade. The only path Elixir code uses to read keys,
  passwords, and credentials. Backed by a local Vault instance (decision §4)
  in production; in dev/test it falls back to the existing
  `Homelab.Settings` encrypted-row path.

  This module is a **stub for now** — the full Vault client lives behind
  the `vault_bootstrap` todo. The API surface below is the contract the
  rest of the codebase commits to, so downstream modules can be written
  against it immediately.

  Reference format: `"secret/homelab/<category>/<...>"`. Examples:

    * `"secret/homelab/restic/<tenant>/lan"` — Tier-1 repo password
    * `"secret/homelab/restic/<tenant>/offsite"` — Tier-3 repo password
    * `"secret/homelab/restic/<tenant>/offsite/s3_creds"` — S3 creds map
    * `"secret/homelab/zfs/pools/<pool>"` — ZFS pool encryption key (raw)
    * `"secret/homelab/registry/<node>"` — per-node registry bearer creds
    * `"secret/homelab/ca/registry"` — internal CA private key
  """

  require Logger

  @type ref :: String.t()

  @doc """
  Returns the secret value for `ref` as a binary, raising on missing/unavailable.
  Used in hot paths where a missing secret is a hard error (e.g. building a
  restic command line — there is no fallback).
  """
  @spec read!(ref()) :: binary()
  def read!(ref) do
    case read(ref) do
      {:ok, value} -> value
      {:error, reason} -> raise "Secret #{inspect(ref)} unavailable: #{inspect(reason)}"
    end
  end

  @doc """
  Returns `{:ok, value}` or `{:error, reason}`. Reasons include
  `:not_found`, `:vault_unavailable`, `:vault_sealed`.
  """
  @spec read(ref()) :: {:ok, binary()} | {:error, term()}
  def read(ref) when is_binary(ref) do
    case backend() do
      :vault ->
        # Wired up by the vault_bootstrap todo. Until then this branch is
        # unreachable; we fall back to Settings below.
        {:error, :vault_unavailable}

      :settings ->
        settings_key = ref_to_settings_key(ref)

        case Homelab.Settings.get(settings_key) do
          nil -> {:error, :not_found}
          value -> {:ok, value}
        end
    end
  end

  @doc """
  Writes a value to `ref`, creating or overwriting. Returns `:ok` or
  `{:error, reason}`.
  """
  @spec write(ref(), binary()) :: :ok | {:error, term()}
  def write(ref, value) when is_binary(ref) and is_binary(value) do
    case backend() do
      :vault ->
        {:error, :vault_unavailable}

      :settings ->
        settings_key = ref_to_settings_key(ref)

        case Homelab.Settings.set(settings_key, value, category: "secret", encrypt: true) do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  @doc """
  Reads `ref`, generating a fresh random value and storing it if missing.
  Used for "auto-provisioned" passwords (decision §20): per-tenant restic
  passwords, ZFS pool keys, registry bearer creds, etc. The caller decides
  the byte length and encoding (raw vs. base64).
  """
  @spec read_or_generate(ref(), generator :: (-> binary())) :: {:ok, binary()} | {:error, term()}
  def read_or_generate(ref, generator) when is_function(generator, 0) do
    case read(ref) do
      {:ok, value} ->
        {:ok, value}

      {:error, :not_found} ->
        value = generator.()

        case write(ref, value) do
          :ok -> {:ok, value}
          err -> err
        end

      err ->
        err
    end
  end

  @doc "Convenience: a 32-byte URL-safe base64 random string. Default generator for §20-style passwords."
  @spec random_password() :: binary()
  def random_password do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  @doc "Convenience: raw 32 bytes (for ZFS keyformat=raw)."
  @spec random_raw_key() :: binary()
  def random_raw_key, do: :crypto.strong_rand_bytes(32)

  # --- Internals ---

  defp backend, do: Application.get_env(:homelab, :secrets_backend, :settings)

  # `secret/homelab/restic/<tenant>/lan` → `secret.restic.<tenant>.lan`
  defp ref_to_settings_key(ref) do
    ref
    |> String.replace_prefix("secret/homelab/", "secret.")
    |> String.replace("/", ".")
  end

  @doc """
  One-shot migration of encrypted `system_settings` rows to Vault refs (§16).
  No-op when Vault backend is not active.
  """
  def migrate_from_settings do
    if backend() != :vault, do: {:ok, 0}, else: {:error, :vault_unavailable}
  end
end
