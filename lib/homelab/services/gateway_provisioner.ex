defmodule Homelab.Services.GatewayProvisioner do
  @moduledoc """
  Auto-provisions the reverse-proxy gateway (Traefik) at startup and keeps it up —
  the ingress-layer analogue of how `Homelab.Bootstrap` auto-provisions Postgres.

  Traefik used to appear only lazily, on the first deploy of a domain-bearing app
  (and only on the legacy deploy path — the saga's `publish_ingress` just connects
  an existing Traefik and no-ops when there is none). That left a fresh box with
  no ingress until someone deployed. This service closes that gap: Traefik comes
  up on boot, unconditionally.

  It can't live in `Bootstrap.ensure_infrastructure` (which runs *before* the Repo)
  because `Infrastructure.ensure_traefik/0` reads Settings (acme_email, base_domain)
  from the database — so it starts under the services supervisor, after the Repo
  and migrations.

  Idempotent and self-healing: `ensure_traefik/0` short-circuits when Traefik is
  already running and recreates it on config drift, and we re-check on a slow
  interval so a daemon that was briefly unavailable at boot — or a
  `TRAEFIK_DNS_API_TOKEN` supplied after the fact — converges without a manual
  deploy. Logs only on state transitions to stay quiet.
  """

  use GenServer

  require Logger

  alias Homelab.Config
  alias Homelab.Infrastructure

  # Small delay so the Docker daemon / network settle after boot before the first
  # attempt; then a slow re-check that self-heals drift and transient failures.
  @boot_delay :timer.seconds(2)
  @interval :timer.minutes(5)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Provisions the gateway synchronously now and returns the ensure result."
  def ensure_now, do: GenServer.call(__MODULE__, :ensure_now)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :ensure, @boot_delay)
    {:ok, %{last: nil}}
  end

  @impl true
  def handle_info(:ensure, state) do
    state = ensure(state)
    Process.send_after(self(), :ensure, @interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:ensure_now, _from, state) do
    state = ensure(state)
    {:reply, state.last, state}
  end

  defp ensure(state) do
    if Config.gateway() == Homelab.Gateways.Traefik do
      result = safe_ensure_traefik()
      log_transition(state.last, result)
      %{state | last: result}
    else
      state
    end
  end

  # Never let a daemon error crash the supervisor into a restart loop; the next
  # tick retries anyway.
  defp safe_ensure_traefik do
    ensure_proxy()
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The same seam, under the same key, as the saga's `EnsureIngressProxy` step and the
  # legacy deploy path: all three ask the same function the same question, and a test
  # that drives one has to be able to drive the others.
  defp ensure_proxy do
    case Application.get_env(:homelab, :ingress_proxy_ensurer) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Infrastructure.ensure_traefik()
    end
  end

  defp log_transition(prev, result) do
    cond do
      result == prev ->
        :ok

      match?({:ok, :started}, result) ->
        Logger.info("GatewayProvisioner: Traefik provisioned")

      match?({:ok, :already_running}, result) and match?({:error, _}, prev) ->
        Logger.info("GatewayProvisioner: Traefik recovered")

      # The remaining successes stay quiet: a first tick that finds Traefik already up
      # is the steady state, not a transition worth a line.
      match?({:ok, _}, result) ->
        :ok

      match?({:error, :dns_token_missing}, result) ->
        Logger.warning(
          "GatewayProvisioner: TRAEFIK_DNS_API_TOKEN is not set — cannot provision Traefik TLS. Set it to enable ingress."
        )

      # A catch-all, NOT `match?({:error, _}, result)`. `ensure_traefik/0` is a `with`
      # with no `else`, so it returns whatever any clause returned — and a shape such as
      # `{:error, :enoent, _}` matches no two-element `{:error, _}`. Falling through to a
      # silent `:ok` would still store that value in `state.last`, and the `result ==
      # prev` short-circuit at the top then keeps every later tick silent too: the one
      # failure class this service cannot classify would be the one it never reports.
      true ->
        Logger.warning("GatewayProvisioner: Traefik provisioning failed: #{inspect(result)}")
    end
  end
end
