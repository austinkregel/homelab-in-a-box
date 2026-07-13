defmodule Homelab.Behaviours.Orchestrator do
  @moduledoc """
  Behaviour for container orchestrators (Docker Swarm, K8s, etc.).

  Implementations translate orchestrator-agnostic service specs into
  platform-specific API calls. Each driver must declare its identity
  via `driver_id/0`, `display_name/0`, and `description/0`.
  """

  @type service_id :: String.t()

  @type service_spec :: %{
          :service_name => String.t(),
          :image => String.t(),
          :env => map(),
          :volumes => [map()],
          :network => String.t(),
          :labels => map(),
          :replicas => pos_integer(),
          :memory_limit => pos_integer(),
          :cpu_limit => pos_integer(),
          :tenant_id => String.t(),
          :deployment_id => String.t(),
          optional(:bridge_networks) => [String.t()],
          optional(:ports) => [map()],
          optional(:service_mode) => boolean(),
          optional(:health_check) => map() | nil,
          # A normalized `Homelab.Deployments.GpuSpec`. Each driver satisfies it with
          # its OWN mechanism -- Engine passes the device directly, Swarm can only
          # reserve a generic resource and let a runtime hook do the injection -- so
          # this stays vendor-intent, not an API payload.
          optional(:gpu) => map() | nil,
          optional(:network_aliases) => [String.t()],
          optional(:command) => [String.t()] | nil,
          optional(:entrypoint) => [String.t()] | nil,
          optional(:user) => String.t() | nil
        }

  @type service_status :: %{
          :id => service_id(),
          :name => String.t(),
          :state => :running | :stopped | :failed | :pending,
          :replicas => non_neg_integer(),
          :image => String.t(),
          :labels => map(),
          optional(:health) => :healthy | :unhealthy | :starting | :none
        }

  @callback driver_id() :: String.t()
  @callback display_name() :: String.t()
  @callback description() :: String.t()

  @callback deploy(service_spec()) :: {:ok, service_id()} | {:error, term()}
  @callback undeploy(service_id()) :: :ok | {:error, term()}

  @doc """
  Grants external reachability to a deployment's network (connects the reverse
  proxy to it). Called only after the deployment is verified ready. Idempotent.
  """
  @callback publish(network :: String.t()) :: :ok | {:error, term()}

  @doc """
  Revokes external reachability for a deployment's network (disconnects the
  reverse proxy from it). Never touches workload containers. Idempotent.
  """
  @callback unpublish(network :: String.t()) :: :ok | {:error, term()}
  @callback update(service_id(), service_spec()) :: :ok | {:error, term()}
  @callback restart(service_id()) :: :ok | {:error, term()}
  @callback list_services() :: {:ok, [service_status()]} | {:error, term()}
  @callback get_service(service_id()) :: {:ok, service_status()} | {:error, term()}
  @callback health_check(service_id()) :: {:ok, :healthy | :unhealthy} | {:error, term()}
  @callback logs(service_id(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback stats(service_id()) :: {:ok, map()} | {:error, term()}

  @type network :: %{name: String.t(), driver: String.t(), labels: map()}
  @type volume :: %{name: String.t(), driver: String.t(), labels: map()}

  @doc "Lists the Docker networks available for wiring workloads to."
  @callback list_networks() :: {:ok, [network()]} | {:error, term()}

  @doc "Lists the Docker volumes available for mounting into workloads."
  @callback list_volumes() :: {:ok, [volume()]} | {:error, term()}
end
