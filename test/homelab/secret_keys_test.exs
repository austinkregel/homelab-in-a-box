defmodule Homelab.SecretKeysTest do
  @moduledoc """
  There were three copies of this predicate with drifting rules — the wizard's, the
  deployment page's and the API serializer's. The deployment page's matched only
  PASSWORD and SECRET, so an `API_TOKEN` was rendered in plaintext on the Environment
  tab while the exact same variable was masked in the wizard.
  """
  use ExUnit.Case, async: true

  alias Homelab.SecretKeys

  describe "sensitive?/1" do
    test "the obvious credential names" do
      for key <- ~w(MYSQL_PASSWORD APP_SECRET GITHUB_TOKEN API_KEY WIREGUARD_PRIVATE_KEY
                    SECRET_KEY_BASE AWS_SECRET_ACCESS_KEY) do
        assert SecretKeys.sensitive?(key), "#{key} should be treated as a secret"
      end
    end

    test "names the narrower copies missed" do
      # `*_PASS` has no "PASSWORD" in it; a connection string embeds its credentials and
      # its name never says so; `*_DSN` and `*_CREDENTIALS` likewise.
      for key <- ~w(SMTP_PASS DATABASE_URL POSTGRES_URI SENTRY_DSN GOOGLE_CREDENTIALS
                    JWT_SIGNING_KEY PASSWORD_SALT BASIC_AUTH) do
        assert SecretKeys.sensitive?(key), "#{key} should be treated as a secret"
      end
    end

    test "an explicitly PUBLIC key is not a secret" do
      # Masking these is its own bug: the operator cannot read a value meant to be read.
      refute SecretKeys.sensitive?("VAPID_PUBLIC_KEY")
      refute SecretKeys.sensitive?("PUBLIC_KEY")
    end

    test "ordinary configuration is left alone" do
      for key <- ~w(APP_ENV TZ PUID PGID LOG_LEVEL SITE_URL PORT VPN_SERVICE_PROVIDER) do
        refute SecretKeys.sensitive?(key), "#{key} should NOT be treated as a secret"
      end
    end

    test "a URL is judged by what it connects to, not by being a URL" do
      assert SecretKeys.sensitive?("DATABASE_URL")
      assert SecretKeys.sensitive?("REDIS_URL")
      refute SecretKeys.sensitive?("SITE_URL")
      refute SecretKeys.sensitive?("WEBHOOK_URL")
    end

    test "nil and non-strings are answered, not raised on" do
      refute SecretKeys.sensitive?(nil)
      refute SecretKeys.sensitive?(123)
      refute SecretKeys.sensitive?(%{})
    end
  end
end
