defmodule Homelab.Catalog.Enrichers.InfraDetector do
  @moduledoc """
  Detects environment variables that relate to platform infrastructure
  (reverse proxy, app URL, OIDC, mail) and suggests auto-fill values
  derived from the system's actual configuration.
  """

  @profiles [
    %{
      id: :proxy,
      label: "Reverse Proxy",
      icon: "hero-shield-check",
      color: "info",
      description: "Proxy trust and forwarding headers",
      env_patterns: ~w(TRUSTED_PROXIES REAL_IP_FROM FORWARDED_FOR SET_REAL_IP_FROM PROXY_TRUSTED),
      resolver: :resolve_proxy
    },
    %{
      id: :app_url,
      label: "Application URL",
      icon: "hero-globe-alt",
      color: "primary",
      description: "Public URL the app is served at",
      env_patterns:
        ~w(APP_URL BASE_URL SITE_URL APPLICATION_URL NEXTAUTH_URL APP_DOMAIN HOSTNAME SERVER_URL),
      resolver: :resolve_app_url
    },
    %{
      id: :oidc,
      label: "OIDC / OAuth",
      icon: "hero-finger-print",
      color: "secondary",
      description: "Identity provider settings from your configured OIDC",
      env_patterns:
        ~w(OIDC_ OAUTH_ OPENID_ AUTH_OIDC AUTH_OAUTH AUTHENTIK_ AUTHELIA_ SOCIAL_AUTH AUTHENTICATION_BACKEND SSO_),
      resolver: :resolve_oidc
    },
    %{
      id: :mail,
      label: "Mail / SMTP",
      icon: "hero-envelope",
      color: "warning",
      description: "Outbound email configuration",
      env_patterns:
        ~w(MAIL_HOST MAIL_PORT MAIL_USERNAME MAIL_PASSWORD MAIL_FROM MAIL_ENCRYPTION SMTP_HOST SMTP_PORT SMTP_USER SMTP_PASSWORD SMTP_FROM EMAIL_HOST EMAIL_PORT),
      resolver: :resolve_mail
    },
    %{
      id: :timezone,
      label: "Timezone / Locale",
      icon: "hero-clock",
      color: "base-content/50",
      description: "System timezone and locale",
      env_patterns: ~w(TZ TIMEZONE LANG LC_ALL),
      resolver: :resolve_timezone
    }
  ]

  @doc """
  Analyzes env vars and returns a list of infrastructure suggestions.

  Each suggestion contains:
  - `:id` — atom like `:proxy`, `:app_url`, etc.
  - `:label` — human-readable name
  - `:icon`, `:color` — for UI rendering
  - `:matched_keys` — which env var keys triggered the match
  - `:fills` — map of env key => suggested value (only for keys that are empty)
  - `:all_fills` — map of env key => suggested value (for all matched keys)
  - `:description` — what this category is about
  """
  def detect(env_vars, opts \\ []) when is_list(env_vars) do
    env_map = Map.new(env_vars, fn e -> {e["key"], e["value"]} end)
    domain = Keyword.get(opts, :domain, "")

    @profiles
    |> Enum.map(fn profile -> {profile, match_keys(env_map, profile)} end)
    |> Enum.filter(fn {_, matched} -> matched != [] end)
    |> Enum.map(fn {profile, matched} ->
      all_fills = apply(__MODULE__, profile.resolver, [matched, env_map, domain])
      fills = Map.filter(all_fills, fn {k, _v} -> blank?(env_map[k]) end)

      %{
        id: profile.id,
        label: profile.label,
        icon: profile.icon,
        color: profile.color,
        description: profile.description,
        matched_keys: matched,
        fills: fills,
        all_fills: all_fills
      }
    end)
    |> Enum.filter(fn s -> s.fills != %{} end)
  end

  defp match_keys(env_map, profile) do
    keys = Map.keys(env_map)

    Enum.filter(keys, fn key ->
      ukey = String.upcase(key)

      Enum.any?(profile.env_patterns, fn pattern ->
        String.starts_with?(ukey, pattern) or ukey == pattern
      end)
    end)
  end

  # -- Resolvers --

  @doc false
  def resolve_proxy(matched_keys, _env_map, _domain) do
    Map.new(matched_keys, fn key ->
      ukey = String.upcase(key)

      value =
        cond do
          String.contains?(ukey, "TRUSTED_PROXIES") -> "172.16.0.0/12,10.0.0.0/8,192.168.0.0/16"
          String.contains?(ukey, "REAL_IP") -> "172.16.0.0/12"
          String.contains?(ukey, "SET_REAL_IP_FROM") -> "172.16.0.0/12"
          String.contains?(ukey, "FORWARDED") -> "X-Forwarded-For"
          true -> "172.16.0.0/12"
        end

      {key, value}
    end)
  end

  @doc false
  def resolve_app_url(matched_keys, _env_map, domain) do
    url =
      if domain != nil and domain != "" do
        "https://#{domain}"
      else
        "https://app.homelab.local"
      end

    Map.new(matched_keys, fn key ->
      ukey = String.upcase(key)

      value =
        cond do
          String.contains?(ukey, "DOMAIN") or String.contains?(ukey, "HOSTNAME") ->
            String.replace_prefix(url, "https://", "")

          true ->
            url
        end

      {key, value}
    end)
  end

  @doc false
  def resolve_oidc(matched_keys, _env_map, _domain) do
    issuer = Homelab.Settings.get("oidc_issuer", "")
    client_id = Homelab.Settings.get("oidc_client_id", "")

    well_known =
      if issuer != "",
        do: String.trim_trailing(issuer, "/") <> "/.well-known/openid-configuration",
        else: ""

    Map.new(matched_keys, fn key ->
      ukey = String.upcase(key)

      value =
        cond do
          String.contains?(ukey, "ISSUER") or String.contains?(ukey, "PROVIDER_URL") or
            String.contains?(ukey, "DISCOVERY") or String.contains?(ukey, "WELL_KNOWN") ->
            issuer

          String.contains?(ukey, "CLIENT_ID") or String.contains?(ukey, "KEY") ->
            client_id

          String.contains?(ukey, "CLIENT_SECRET") or String.contains?(ukey, "SECRET") ->
            Homelab.Settings.get("oidc_client_secret", "")

          String.contains?(ukey, "REDIRECT") or String.contains?(ukey, "CALLBACK") ->
            ""

          String.contains?(ukey, "AUTHORIZE") ->
            well_known

          true ->
            ""
        end

      {key, value}
    end)
    |> Map.reject(fn {_k, v} -> v == "" end)
  end

  @doc false
  def resolve_mail(matched_keys, _env_map, _domain) do
    Map.new(matched_keys, fn key ->
      ukey = String.upcase(key)

      value =
        cond do
          String.contains?(ukey, "HOST") -> ""
          String.contains?(ukey, "PORT") -> "587"
          String.contains?(ukey, "ENCRYPTION") or String.contains?(ukey, "SECURE") -> "tls"
          String.contains?(ukey, "FROM") -> "noreply@homelab.local"
          true -> ""
        end

      {key, value}
    end)
    |> Map.reject(fn {_k, v} -> v == "" end)
  end

  @doc false
  def resolve_timezone(matched_keys, _env_map, _domain) do
    system_tz =
      case System.cmd("cat", ["/etc/timezone"], stderr_to_stdout: true) do
        {tz, 0} -> String.trim(tz)
        _ -> "UTC"
      end

    Map.new(matched_keys, fn key ->
      ukey = String.upcase(key)

      value =
        cond do
          ukey in ~w(TZ TIMEZONE) -> system_tz
          ukey == "LANG" -> "en_US.UTF-8"
          ukey == "LC_ALL" -> "en_US.UTF-8"
          true -> system_tz
        end

      {key, value}
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
