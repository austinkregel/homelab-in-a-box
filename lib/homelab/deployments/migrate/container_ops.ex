defmodule Homelab.Deployments.Migrate.ContainerOps do
  @moduledoc """
  Behaviour for the container lifecycle operations the quiesce/resume steps need.
  `Homelab.Deployments.Migrate.ContainerControl` is the live implementation;
  tests inject a stub so the step handlers run without a daemon.
  """

  @callback restart_policy(id :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback set_restart_policy(id :: String.t(), name :: String.t()) :: :ok | {:error, term()}
  @callback stop(id :: String.t(), timeout_seconds :: non_neg_integer()) :: :ok | {:error, term()}
  @callback start(id :: String.t()) :: :ok | {:error, term()}

  @doc "Container runtime env as a `%{KEY => VALUE}` string map."
  @callback env(id :: String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}

  @doc "Image baked-in env as a `%{KEY => VALUE}` string map (to diff against)."
  @callback image_env(image :: String.t()) ::
              {:ok, %{String.t() => String.t()}} | {:error, term()}

  @doc "The container's published host ports in SpecBuilder's ports_override shape."
  @callback port_bindings(id :: String.t()) :: {:ok, [map()]} | {:error, term()}
end
