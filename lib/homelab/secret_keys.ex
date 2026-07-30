defmodule Homelab.SecretKeys do
  @moduledoc """
  The one answer to "does this environment variable hold a credential?"

  Used to decide whether a value is masked in the UI, redacted from the API, and shared
  as a generated password when wiring an app to a datastore.

  There were three copies of this with drifting rules — the wizard's, the deployment
  page's and the API serializer's — which meant a key could be masked on one screen and
  printed on another. The API's version was the strictest; this is that one, widened.

  ## It is a heuristic, and the limits are worth stating

  It matches on the NAME, because the value is opaque. So it catches
  `WIREGUARD_PRIVATE_KEY` and misses a credential whose name says nothing —
  `DATABASE_URL` and `AMQP_URI` embed a password in a connection string, and `*_PASS`,
  `*_DSN` and `*_CREDENTIALS` were all missed by the narrower versions. Those are
  included below. Anything genuinely unnameable still leaks, and the honest fix for that
  is per-variable marking, not a longer list.

  `PUBLIC` is an explicit exclusion: `PUBLIC_KEY` and `VAPID_PUBLIC_KEY` are meant to be
  read.
  """

  # `PASS` rather than `PASSWORD` so `SMTP_PASS` and `DB_PASS` are caught — both were
  # missed by all three of the copies this replaces. It subsumes PASSWORD and PASSWD.
  @needles ~w(PASS SECRET TOKEN CREDENTIAL PRIVATE_KEY APIKEY API_KEY
              DSN AUTH SALT SIGNING)

  @doc """
  True when a variable name suggests it holds a credential.

  Accepts nil and non-strings so callers can pass a raw form value without guarding.
  """
  @spec sensitive?(term()) :: boolean()
  def sensitive?(key) when is_binary(key) do
    upper = String.upcase(key)

    cond do
      # An explicitly PUBLIC key is meant to be read.
      String.contains?(upper, "PUBLIC") -> false
      Enum.any?(@needles, &String.contains?(upper, &1)) -> true
      # A bare `KEY` (e.g. `SECRET_KEY_BASE`, `API_KEY`) — after the PUBLIC exclusion.
      String.contains?(upper, "KEY") -> true
      # A connection string carries its credentials inline, and its name never says so.
      String.ends_with?(upper, "_URL") or String.ends_with?(upper, "_URI") -> connection?(upper)
      true -> false
    end
  end

  def sensitive?(_key), do: false

  @doc "The mask shown in place of a secret's value."
  @spec mask() :: String.t()
  def mask, do: "••••••"

  # `DATABASE_URL` embeds a password; `SITE_URL` does not. Distinguishing them by name is
  # the best available signal short of parsing the value.
  defp connection?(upper) do
    Enum.any?(
      ~w(DATABASE DB_ POSTGRES MYSQL MARIADB MONGO REDIS AMQP RABBIT SMTP S3 MINIO),
      &String.contains?(upper, &1)
    )
  end
end
