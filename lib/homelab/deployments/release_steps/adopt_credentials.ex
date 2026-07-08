defmodule Homelab.Deployments.ReleaseSteps.AdoptCredentials do
  @moduledoc """
  Imports the user-supplied environment of the container being adopted into the
  deployment's encrypted secrets, so the managed replacement starts with the same
  credentials the original used.

  It diffs the live container's env against the image's baked-in env and keeps
  only the pairs the operator actually set (dropping image defaults and the
  always-noise `PATH`/`HOME`). Each surviving pair is stored via
  `Releases.put_secret/3` (encrypted at rest) — never as plaintext in the
  AppTemplate. Zero user env is an honest success.

  Expects `step.resource_handle` with `"container"` (id/name) and `"image"`.
  `compensate/2` deletes exactly the keys it imported.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments.Migrate.ContainerControl
  alias Homelab.Deployments.Releases

  @always_drop ~w(PATH HOME)

  @impl true
  def run(step, ctx) do
    container = step.resource_handle["container"]
    image = step.resource_handle["image"]

    with {:ok, container_env} <- ops().env(container),
         {:ok, image_env} <- image_env(image) do
      user_env = user_supplied_env(container_env, image_env)

      Enum.each(user_env, fn {key, value} ->
        Releases.put_secret(ctx.deployment.id, key, value)
      end)

      keys = Map.keys(user_env)
      Logger.info("[adopt_credentials] imported #{length(keys)} env var(s) for #{container}")
      {:ok, %{"imported_keys" => keys, "container" => container}}
    else
      {:error, reason} -> {:error, {:adopt_credentials_failed, container, reason}}
    end
  end

  @impl true
  def compensate(step, ctx) do
    keys = step.resource_handle["imported_keys"] || []
    _ = Releases.delete_secrets(ctx.deployment.id, keys)
    :ok
  end

  # Keep only pairs whose value differs from the image default, minus PATH/HOME.
  defp user_supplied_env(container_env, image_env) do
    container_env
    |> Enum.reject(fn {key, value} ->
      key in @always_drop or Map.get(image_env, key) == value
    end)
    |> Map.new()
  end

  # An adopted image may not be pullable/inspectable; treat inspection failure as
  # "no baked-in env" rather than failing the whole import.
  defp image_env(nil), do: {:ok, %{}}

  defp image_env(image) do
    case ops().image_env(image) do
      {:ok, env} -> {:ok, env}
      {:error, _reason} -> {:ok, %{}}
    end
  end

  defp ops, do: Application.get_env(:homelab, :container_ops, ContainerControl)
end
