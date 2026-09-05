defmodule Homelab.Auth.MachineToken do
  @moduledoc """
  Resolves an OAuth2 `client_credentials` bearer token to the local `:service` row for
  the machine presenting it, via the issuer's `machine_info_endpoint` (the machine-grant
  counterpart to `userinfo`, which has no answer for a token with no user).

  The issuer validates the token — we do not check signatures — so revocation is
  immediate at the cost of a round trip per request. Only the discovery document is
  cached, never the token result.

  A token must also carry `required_scope/0` (`oidc_machine_scope`, default `homelab`);
  register it in the issuer first. Scopes are returned, not stored.
  """

  require Logger

  alias Homelab.Accounts
  alias Homelab.Audit
  alias Homelab.Auth.OidcDiscovery
  alias Homelab.Settings

  @cache_table :homelab_oidc_discovery_cache
  @discovery_ttl_ms :timer.minutes(10)
  @default_scope "homelab"
  @timeout 10_000

  @type failure ::
          :not_configured
          | :no_machine_info_endpoint
          | :invalid_token
          | :insufficient_scope
          | {:http_error, pos_integer()}
          | {:connection_error, term()}
          | :missing_client_id

  @doc "Authenticates a bearer token, returning the machine's row and the issuer's scopes."
  @spec authenticate(String.t()) ::
          {:ok, Homelab.Accounts.User.t(), [String.t()]} | {:error, failure()}
  def authenticate(token) when is_binary(token) do
    with {:ok, endpoint} <- machine_info_endpoint(),
         {:ok, body} <- fetch_machine_info(endpoint, token),
         scopes = scopes(body),
         :ok <- check_scope(scopes),
         {:ok, user} <- upsert(body) do
      {:ok, touch(user), scopes}
    end
  end

  def authenticate(_token), do: {:error, :invalid_token}

  @doc "The scope a token must carry to reach this instance's API at all."
  @spec required_scope() :: String.t()
  def required_scope do
    case Settings.get("oidc_machine_scope") do
      scope when is_binary(scope) ->
        if String.trim(scope) == "", do: @default_scope, else: String.trim(scope)

      _ ->
        @default_scope
    end
  end

  # --- Issuer -----------------------------------------------------------------

  defp machine_info_endpoint do
    with {:ok, issuer} <- configured_issuer(),
         {:ok, discovery} <- cached_discovery(issuer) do
      endpoint_from(discovery)
    end
  end

  defp configured_issuer do
    case Settings.get("oidc_issuer") do
      issuer when is_binary(issuer) and issuer != "" -> {:ok, issuer}
      _ -> {:error, :not_configured}
    end
  end

  defp endpoint_from(discovery) do
    if OidcDiscovery.supports_machine_info?(discovery) do
      {:ok, discovery.machine_info_endpoint}
    else
      {:error, :no_machine_info_endpoint}
    end
  end

  # Cached because an agent makes many calls; each would otherwise cost two round trips.
  defp cached_discovery(issuer) do
    init_cache()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache_table, issuer) do
      [{^issuer, discovery, expires_at}] when expires_at > now ->
        {:ok, discovery}

      _ ->
        case OidcDiscovery.discover(issuer) do
          {:ok, discovery} ->
            :ets.insert(@cache_table, {issuer, discovery, now + @discovery_ttl_ms})
            {:ok, discovery}

          error ->
            error
        end
    end
  end

  defp init_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  @doc "Drops the cached discovery documents."
  def reset_cache do
    init_cache()
    :ets.delete_all_objects(@cache_table)
    :ok
  end

  defp fetch_machine_info(endpoint, token) do
    case Req.get(endpoint,
           headers: [{"authorization", "Bearer #{token}"}],
           retry: false,
           receive_timeout: @timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      # machine-info itself requires the `openid` scope; 403 is not a bad token.
      {:ok, %Req.Response{status: 403}} ->
        {:error, :insufficient_scope}

      {:ok, %Req.Response{status: status}} when status in [400, 401] ->
        {:error, :invalid_token}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("machine-info returned #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("machine-info connection error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp scopes(body) do
    case body["scopes"] || body["scope"] do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      # RFC 6749 allows one space-delimited string; aut.hair sends a list.
      str when is_binary(str) -> String.split(str, " ", trim: true)
      _ -> []
    end
  end

  defp check_scope(scopes) do
    if required_scope() in scopes, do: :ok, else: {:error, :insufficient_scope}
  end

  # --- Local row ----------------------------------------------------------------

  defp upsert(body) do
    known? = match?(%{}, Accounts.get_user_by_sub("service:#{body["client_id"]}"))

    case Accounts.get_or_create_service_account(body) do
      {:ok, user} ->
        unless known?, do: log_first_sighting(user)
        {:ok, user}

      {:error, %Ecto.Changeset{}} ->
        {:error, :missing_client_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only the first sighting; later calls write last_login_at so a busy agent stays quiet.
  defp log_first_sighting(user) do
    _ =
      Audit.log("service_account.first_seen", "user", user.id,
        user_id: user.id,
        metadata: %{"sub" => user.sub, "name" => user.name}
      )

    Logger.info("New service account authenticated: #{user.sub} (#{user.name})")
  end

  defp touch(user) do
    case Accounts.update_last_login(user) do
      {:ok, updated} -> updated
      _ -> user
    end
  end
end
