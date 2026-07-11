defmodule Homelab.Auth.BreakGlass do
  @moduledoc """
  Emergency, non-OIDC admin login — a **one-time** token, not a standing backdoor.

  The homelab enforces OIDC on every route, but the OIDC provider can be a
  service hosted *on this homelab* (see `Homelab.Deployments.Adoption`). When
  that provider is down — a fresh box, a reboot race, a cert renewal, a botched
  config — normal login is impossible and the operator is locked out with no way
  to reach the UI that would fix it.

  Break-glass is the way back in, and it is deliberately single-use:

    * The secret lives in a **file on disk** (default `<secrets>/breakglass_token`,
      in the `homelab-iab-secrets` volume), never in an env var or the database.
      "Arm" break-glass by writing a >= 24-char token to that file, or call
      `arm!/0` to generate one.
    * A **successful** login `consume/0`s the file — it is deleted, so the same
      token can never be used again. A failed attempt does NOT consume it, so a
      wrong guess can't lock the legitimate operator out.
    * No file (or a too-short one) => the feature, route included, does not exist.

  Every use, success or failure, is written loudly to the audit log by the
  controller. Once OIDC is healthy again, log in normally; break-glass is already
  spent and stays that way until re-armed.
  """

  require Logger

  # Enough entropy that an operator can't accidentally arm break-glass with a
  # guessable token. 24 chars ~= 128 bits when generated with `openssl rand`.
  @min_token_length 24
  @token_bytes 32

  @doc "True only when the token file holds a sufficiently long token."
  def enabled?, do: valid_token?(read_token())

  @doc "The current break-glass token from the file, or nil."
  def token, do: read_token()

  @doc "Absolute path of the token file (nil if unconfigured)."
  def token_file, do: config()[:token_file]

  @doc "A human label for the break-glass admin (audit/identity), defaults to \"breakglass\"."
  def user_label, do: config()[:user] || "breakglass"

  @doc """
  Constant-time check of a presented token against the file's contents. False
  whenever break-glass is disabled (no/short token), regardless of what was given.
  """
  def verify(presented) when is_binary(presented) do
    case read_token() do
      t when is_binary(t) -> valid_token?(t) and Plug.Crypto.secure_compare(presented, t)
      _ -> false
    end
  end

  def verify(_), do: false

  @doc """
  Consumes the token by deleting the file, so it cannot be reused. Best-effort
  and idempotent, but a failure here means the token is STILL LIVE — logged loudly
  so the operator can remove the file by hand.
  """
  def consume do
    case token_file() do
      path when is_binary(path) ->
        case File.rm(path) do
          :ok ->
            Logger.warning("BREAK-GLASS: token consumed (#{path})")
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "BREAK-GLASS: FAILED to consume token #{path}: #{inspect(reason)} — token is STILL LIVE, remove the file manually"
            )

            {:error, reason}
        end

      _ ->
        :ok
    end
  end

  @doc """
  Generates a fresh one-time token, writes it to the token file (mode 0600), and
  returns the plaintext for the operator to copy. Overwrites any existing token.

  Convenience for the prod release image (has `bin/homelab`):

      docker exec homelab bin/homelab rpc 'IO.puts(Homelab.Auth.BreakGlass.arm!())'

  Portable in any image (incl. the source-mounted dev container, which has no
  release binary) — just write the file the app reads:

      docker exec homelab sh -c 'od -An -N24 -tx1 /dev/urandom | tr -d " \\n" \\
        | tee /run/secrets/breakglass_token; chmod 600 /run/secrets/breakglass_token'
  """
  def arm! do
    path = token_file() || raise "break-glass token_file is not configured"

    token =
      @token_bytes
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)
      |> binary_part(0, @token_bytes)

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, token)
    _ = File.chmod(path, 0o600)
    Logger.warning("BREAK-GLASS: armed with a new one-time token at #{path}")
    token
  end

  defp valid_token?(t) when is_binary(t), do: byte_size(t) >= @min_token_length
  defp valid_token?(_), do: false

  defp read_token do
    case token_file() do
      path when is_binary(path) ->
        case File.read(path) do
          {:ok, contents} -> String.trim(contents)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp config, do: Application.get_env(:homelab, :breakglass, [])
end
