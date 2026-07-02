defmodule Homelab.Docker.RegistryAuth do
  @moduledoc """
  Builds the `X-Registry-Auth` header the Docker Engine API expects for
  authenticated pulls, pushes, and Swarm service creates against the
  self-hosted registry.

  The header value is base64url(JSON) of an `AuthConfig`
  (`{"username","password","serveraddress"}`). On Swarm `/services/create`,
  the daemon stores this and distributes it to worker nodes — the API
  equivalent of `docker service create --with-registry-auth`.
  """

  alias Homelab.Config

  @doc """
  Builds the `X-Registry-Auth` header tuple from an auth config map.
  """
  def header(%{username: username, password: password} = cfg) do
    payload = %{
      "username" => username,
      "password" => password,
      "serveraddress" => Map.get(cfg, :serveraddress, Config.registry_ref_prefix())
    }

    encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    {"X-Registry-Auth", encoded}
  end

  @doc """
  Returns the `X-Registry-Auth` header for an image ref that lives in the
  self-hosted registry, or `nil` for public images (which need no auth).
  """
  def for_ref(image_ref) when is_binary(image_ref) do
    prefix = Config.registry_ref_prefix()

    if prefix && String.starts_with?(image_ref, prefix <> "/") do
      case Config.registry_credentials() do
        {username, password} when is_binary(username) and is_binary(password) ->
          header(%{username: username, password: password, serveraddress: prefix})

        _ ->
          nil
      end
    else
      nil
    end
  end

  def for_ref(_), do: nil
end
