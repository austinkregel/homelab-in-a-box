defmodule Homelab.Docker.RegistryAuth do
  @moduledoc """
  Builds the `X-Registry-Auth` header the Docker Engine API expects for
  authenticated pulls, pushes, and Swarm service creates against the
  self-hosted registry.

  The header value is base64url(JSON) of an `AuthConfig`
  (`{"username","password","serveraddress"}`). On Swarm `/services/create`,
  the daemon stores this and distributes it to worker nodes — the API
  equivalent of `docker service create --with-registry-auth`.

  The padding on that base64 is NOT optional. The daemon decodes the header with
  Go's `base64.URLEncoding`, the *padded* alphabet, and an unpadded value simply
  fails to decode — whereupon the daemon does not reject the request, it quietly
  falls back to an ANONYMOUS pull. A private image then comes back 401/unauthorized
  no matter how correct the credentials were, which is indistinguishable from having
  sent no header at all. Verified against a live daemon: a padded header with bad
  credentials gets "denied" from the registry (they were evaluated), an unpadded one
  gets "unauthorized" (they were never sent).
  """

  require Logger

  alias Homelab.Config

  @doc """
  Builds the `X-Registry-Auth` header tuple from an auth config map.
  """
  def header(%{username: username, password: password} = cfg) do
    encode(%{
      "username" => username,
      "password" => password,
      "serveraddress" => Map.get(cfg, :serveraddress, Config.registry_ref_prefix())
    })
  end

  @doc """
  Returns the `X-Registry-Auth` header for an image ref that needs authentication,
  or `nil` for a public image (which needs none).
  """
  def for_ref(image_ref) do
    case auth_config_for_ref(image_ref) do
      nil -> nil
      auth_config -> encode(auth_config)
    end
  end

  @doc """
  Request options carrying the `X-Registry-Auth` header for `image_ref`, or `[]` when
  it needs no auth.

  Logs what was resolved (never the password). A registry 401 is otherwise mute
  about *why* — an image pulled with no header and one pulled with a bad password
  fail identically — so say up front whether credentials were attached, and for whom.
  """
  @spec request_opts(String.t()) :: keyword()
  def request_opts(image_ref) do
    case auth_config_for_ref(image_ref) do
      nil ->
        Logger.info("[RegistryAuth] #{image_ref}: no credentials configured, pulling anonymously")
        []

      %{"username" => username, "serveraddress" => host} = auth_config ->
        Logger.info(
          "[RegistryAuth] #{image_ref}: authenticating to #{host} as #{inspect(username)}"
        )

        [headers: [encode(auth_config)]]
    end
  end

  @doc """
  The `AuthConfig` (`%{"username", "password", "serveraddress"}`) that authenticates
  `image_ref` — the self-hosted registry, or any configured registry driver
  advertising `:pull_auth` (e.g. GHCR) whose host the ref lives on. `nil` for a
  public image.

  Exposed separately from `for_ref/1` because the Docker daemon is not the only
  thing that has to authenticate: the catalog's image inspector talks to the
  registry's HTTP API directly and needs the same credentials in a different shape.
  """
  def auth_config_for_ref(image_ref) when is_binary(image_ref) do
    self_hosted_auth(image_ref) || registry_driver_auth(image_ref)
  end

  def auth_config_for_ref(_), do: nil

  defp self_hosted_auth(image_ref) do
    prefix = Config.registry_ref_prefix()

    if prefix && String.starts_with?(image_ref, prefix <> "/") do
      case Config.registry_credentials() do
        {username, password} when is_binary(username) and is_binary(password) ->
          %{"username" => username, "password" => password, "serveraddress" => prefix}

        _ ->
          nil
      end
    end
  end

  # A configured registry driver's AuthConfig names the host it authenticates
  # against, so that `serveraddress` is also what decides whether a ref belongs to
  # it. Without this, a private image on a third-party registry (a private GHCR
  # package) is pulled anonymously and the daemon 401s.
  defp registry_driver_auth(image_ref) do
    Config.registries()
    |> Enum.filter(&pull_auth?/1)
    |> Enum.find_value(fn registry ->
      with {:ok, %{"serveraddress" => host} = auth_config} <- registry.pull_auth_config(),
           true <- is_binary(host) and host != "",
           true <- String.starts_with?(image_ref, host <> "/") do
        auth_config
      else
        _ -> nil
      end
    end)
  end

  defp pull_auth?(registry) do
    Code.ensure_loaded?(registry) and function_exported?(registry, :pull_auth_config, 0)
  end

  # padding: true (the default) is load-bearing — see the moduledoc.
  defp encode(payload) do
    {"X-Registry-Auth", payload |> Jason.encode!() |> Base.url_encode64()}
  end
end
