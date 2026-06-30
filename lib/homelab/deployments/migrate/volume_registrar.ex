defmodule Homelab.Deployments.Migrate.VolumeRegistrar do
  @moduledoc """
  Behaviour for registering / removing the plane-managed volume that backs an
  adopted mount. `Homelab.Deployments.PermanentHome` is the production
  implementation (device-bind named volumes); tests inject a stub so the
  migration handler can run without a live daemon.
  """

  @callback ensure_volume(service :: String.t(), container_path :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback remove_volume(name :: String.t()) :: :ok | {:error, term()}
end
