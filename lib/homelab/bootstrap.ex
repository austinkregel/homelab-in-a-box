defmodule Homelab.Bootstrap do
  @moduledoc """
  Self-bootstrapping infrastructure provisioner.

  When running inside a Docker container with the host's Docker socket
  mounted, this module ensures Postgres is running before the Repo starts.
  In development mode (when Postgres config is already provided), it's a no-op.
  """

  require Logger

  alias Homelab.Docker.Client

  # Names are prefixed `homelab-iab-` so this app's self-provisioned Postgres
  # never collides with an unrelated `homelab-postgres` container that may
  # already exist on the host (e.g. a shared database in another compose stack).
  @postgres_container "homelab-iab-postgres"
  @postgres_volume "homelab-iab-postgres-data"
  @secrets_volume "homelab-iab-secrets"
  # Namespaced `homelab-iab-` like the plane's other resources: a bare
  # `homelab-internal` would collide with a network an existing stack may already
  # own — and this module both CREATES and (via build_from_scratch) removes it.
  @network "homelab-iab-internal"
  # The app DB runs TimescaleDB (PostgreSQL 17 + the timescaledb extension) so the
  # `metric_samples` time-series table can be a hypertable. The migration falls back
  # to a plain BRIN-indexed table when the extension is absent, so this is an
  # optimization rather than a hard requirement.
  @postgres_image "timescale/timescaledb:2.17.2-pg17"
  @postgres_image_repo "timescale/timescaledb"
  @postgres_image_tag "2.17.2-pg17"
  @postgres_user "homelab"
  @postgres_db "homelab_prod"
  # Dedicated Postgres instance for Oban, isolated from the app DB. It holds no
  # time-series data, so it stays on stock Postgres.
  @oban_postgres_container "homelab-iab-oban-postgres"
  @oban_postgres_volume "homelab-iab-oban-postgres-data"
  @oban_postgres_db "homelab_oban_prod"
  @oban_postgres_image "postgres:17-alpine"
  @oban_postgres_image_repo "postgres"
  @oban_postgres_image_tag "17-alpine"
  @secrets_path "/run/secrets"
  @password_file "pg_password"
  @max_wait_attempts 30
  @wait_interval_ms 1_000

  @doc """
  Ensures infrastructure is ready. Called before the Repo starts.

  Returns `:ok` when bootstrap is not needed (dev/test) or when
  infrastructure has been provisioned successfully.
  """
  def ensure_infrastructure do
    if bootstrap_enabled?() do
      Logger.info("Bootstrap: provisioning infrastructure...")

      with :ok <- ensure_network(),
           :ok <- connect_self_to_network(),
           :ok <- ensure_volumes(),
           {:ok, password} <- ensure_password(),
           :ok <- ensure_postgres(password),
           :ok <- wait_for_postgres(),
           :ok <- wait_for_tcp_connection(),
           :ok <- configure_repo(password),
           :ok <- ensure_oban_postgres(password),
           :ok <- wait_for_oban_postgres(),
           :ok <- configure_oban_repo(password) do
        Logger.info("Bootstrap: infrastructure ready")
        :ok
      else
        {:error, reason} ->
          Logger.error("Bootstrap failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      :ok
    end
  end

  @doc """
  Runs Ecto migrations programmatically. Called after the Repo is started.
  """
  def run_migrations do
    Logger.info("Bootstrap: running migrations...")

    Ecto.Migrator.run(
      Homelab.Repo,
      Ecto.Migrator.migrations_path(Homelab.Repo),
      :up,
      all: true,
      log: :info
    )

    Ecto.Migrator.run(
      Homelab.ObanRepo,
      Ecto.Migrator.migrations_path(Homelab.ObanRepo),
      :up,
      all: true,
      log: :info
    )

    maybe_seed_from_env()

    :ok
  end

  @doc """
  Seeds system settings and a default tenant from environment variables.
  Only runs when `HOMELAB_SEED_SETUP=true` is set and setup hasn't been
  completed yet. Used to skip the setup wizard during development.
  """
  def maybe_seed_from_env do
    if System.get_env("HOMELAB_SEED_SETUP") == "true" and
         not Homelab.Settings.setup_completed?() do
      Logger.info("Bootstrap: seeding setup from environment variables...")

      seed_pairs = [
        {"HOMELAB_INSTANCE_NAME", "instance_name", []},
        {"HOMELAB_BASE_DOMAIN", "base_domain", []},
        {"HOMELAB_OIDC_ISSUER", "oidc_issuer", []},
        {"HOMELAB_OIDC_CLIENT_ID", "oidc_client_id", []},
        {"HOMELAB_OIDC_CLIENT_SECRET", "oidc_client_secret", [encrypt: true]},
        {"HOMELAB_ORCHESTRATOR", "orchestrator", []},
        {"HOMELAB_GATEWAY", "gateway", []}
      ]

      Enum.each(seed_pairs, fn {env_key, setting_key, opts} ->
        case System.get_env(env_key) do
          nil -> :ok
          "" -> :ok
          value -> Homelab.Settings.set(setting_key, value, opts)
        end
      end)

      seed_default_tenant()

      # Only mark setup complete if OIDC actually got configured. Marking it
      # complete without an issuer/client_id turns on auth enforcement with
      # nowhere to send the user: / -> /auth/oidc -> /setup -> / forever. Leaving
      # it incomplete lets the setup wizard (or break-glass) resolve it instead.
      if oidc_configured?() do
        Homelab.Settings.mark_setup_completed()
        Logger.info("Bootstrap: setup seeded and marked complete")
      else
        Logger.warning(
          "Bootstrap: OIDC issuer/client_id not provided — leaving setup incomplete so the wizard runs (set HOMELAB_OIDC_ISSUER + HOMELAB_OIDC_CLIENT_ID, or use break-glass)."
        )
      end
    end
  end

  defp oidc_configured? do
    present? = fn key -> Homelab.Settings.get(key) not in [nil, ""] end
    present?.("oidc_issuer") and present?.("oidc_client_id")
  end

  defp seed_default_tenant do
    alias Homelab.Tenants

    case Tenants.get_tenant_by_slug("development") do
      {:ok, _tenant} ->
        :ok

      {:error, _} ->
        case Tenants.create_tenant(%{name: "Development", slug: "development"}) do
          {:ok, _} ->
            Logger.info("Bootstrap: created default 'Development' tenant")

          {:error, reason} ->
            Logger.warning("Bootstrap: tenant creation failed: #{inspect(reason)}")
        end
    end
  end

  defp bootstrap_enabled? do
    Application.get_env(:homelab, :bootstrap, false)
  end

  # Overridable in tests to avoid real sleeps / DNS. Defaults preserve prod behavior.
  defp wait_opts do
    Application.get_env(:homelab, :bootstrap_wait,
      attempts: @max_wait_attempts,
      interval_ms: @wait_interval_ms
    )
  end

  defp wait_attempts, do: Keyword.get(wait_opts(), :attempts, @max_wait_attempts)
  defp wait_interval_ms, do: Keyword.get(wait_opts(), :interval_ms, @wait_interval_ms)

  defp tcp_target do
    Application.get_env(:homelab, :bootstrap_tcp_target, {~c"#{@postgres_container}", 5432})
  end

  # Runs before the Repo starts, so the orchestrator setting — a database read —
  # is not available here. `Homelab.Docker.Network` keys the driver off the
  # daemon's swarm state instead, which is precisely what makes it callable from
  # this far down in the boot sequence.
  defp ensure_network do
    Logger.info("Bootstrap: ensuring network #{@network}")

    case Homelab.Docker.Network.ensure(@network) do
      :ok -> :ok
      {:error, {:network_create_failed, reason}} -> {:error, {:network_failed, reason}}
      {:error, reason} -> {:error, {:network_check_failed, reason}}
    end
  end

  defp connect_self_to_network do
    container_id = get_own_container_id()

    if container_id do
      case Client.get("/networks/#{@network}") do
        {:ok, %{"Containers" => containers}} when is_map(containers) ->
          if Map.has_key?(containers, container_id) do
            Logger.info("Bootstrap: already connected to #{@network}")
            :ok
          else
            do_connect_to_network(container_id)
          end

        {:ok, _} ->
          do_connect_to_network(container_id)

        {:error, reason} ->
          Logger.warning("Bootstrap: could not check network membership: #{inspect(reason)}")
          :ok
      end
    else
      Logger.warning("Bootstrap: could not determine own container ID, skipping network join")
      :ok
    end
  end

  defp do_connect_to_network(container_id) do
    Logger.info("Bootstrap: connecting self to #{@network}")

    case Client.post("/networks/#{@network}/connect", %{"Container" => container_id}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Bootstrap: failed to join network: #{inspect(reason)}")
        :ok
    end
  end

  defp get_own_container_id do
    hostname = System.get_env("HOSTNAME")

    cond do
      hostname && String.match?(hostname, ~r/^[a-f0-9]{12,64}$/) ->
        hostname

      File.exists?("/proc/self/cgroup") ->
        case File.read("/proc/self/cgroup") do
          {:ok, content} ->
            content
            |> String.split("\n")
            |> Enum.find_value(fn line ->
              case Regex.run(~r|/docker/([a-f0-9]{64})|, line) do
                [_, id] -> id
                _ -> nil
              end
            end)

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp wait_for_tcp_connection do
    Logger.info("Bootstrap: verifying TCP connection to Postgres...")
    do_wait_for_tcp(0)
  end

  defp do_wait_for_tcp(attempt) do
    if attempt >= wait_attempts() do
      {:error, :postgres_tcp_timeout}
    else
      {host, port} = tcp_target()

      case :gen_tcp.connect(host, port, [], 2_000) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          Logger.info("Bootstrap: TCP connection to Postgres confirmed")
          :ok

        {:error, _} ->
          Process.sleep(wait_interval_ms())
          do_wait_for_tcp(attempt + 1)
      end
    end
  end

  defp ensure_volumes do
    Enum.reduce_while([@postgres_volume, @secrets_volume], :ok, fn vol, :ok ->
      case ensure_volume(vol) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp ensure_volume(name) do
    case Client.get("/volumes/#{name}") do
      {:ok, _} ->
        :ok

      {:error, {:not_found, _}} ->
        Logger.info("Bootstrap: creating volume #{name}")

        case Client.post("/volumes/create", %{"Name" => name}) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:volume_failed, name, reason}}
        end

      {:error, reason} ->
        {:error, {:volume_check_failed, name, reason}}
    end
  end

  defp ensure_password do
    password_path = Path.join(@secrets_path, @password_file)

    if File.exists?(password_path) do
      {:ok, String.trim(File.read!(password_path))}
    else
      password = generate_password(48)

      case File.mkdir_p(@secrets_path) do
        :ok ->
          File.write!(password_path, password)
          {:ok, password}

        {:error, _} ->
          {:ok, password}
      end
    end
  end

  defp ensure_postgres(password) do
    case Client.get("/containers/#{@postgres_container}/json") do
      {:ok, %{"State" => %{"Running" => true}}} ->
        Logger.info("Bootstrap: Postgres already running")
        :ok

      {:ok, %{"State" => %{"Running" => false}}} ->
        Logger.info("Bootstrap: starting existing Postgres container")

        case Client.post("/containers/#{@postgres_container}/start") do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:postgres_start_failed, reason}}
        end

      {:error, {:not_found, _}} ->
        create_postgres(password)

      {:error, reason} ->
        {:error, {:postgres_check_failed, reason}}
    end
  end

  defp create_postgres(password) do
    Logger.info("Bootstrap: pulling #{@postgres_image}...")

    _ =
      Client.post("/images/create?fromImage=#{@postgres_image_repo}&tag=#{@postgres_image_tag}")

    Logger.info("Bootstrap: creating Postgres container")

    body = %{
      "Image" => @postgres_image,
      # Load the extension library explicitly: the TimescaleDB entrypoint only
      # writes `shared_preload_libraries` on a fresh initdb, so a data volume
      # first created by stock Postgres would otherwise reject CREATE EXTENSION.
      "Cmd" => ["postgres", "-c", "shared_preload_libraries=timescaledb"],
      "Env" => [
        "POSTGRES_USER=#{@postgres_user}",
        "POSTGRES_PASSWORD=#{password}",
        "POSTGRES_DB=#{@postgres_db}"
      ],
      "HostConfig" => %{
        "NetworkMode" => @network,
        "Mounts" => [
          %{
            "Type" => "volume",
            "Source" => @postgres_volume,
            "Target" => "/var/lib/postgresql/data"
          }
        ],
        "RestartPolicy" => %{"Name" => "unless-stopped"}
      },
      "Healthcheck" => %{
        "Test" => ["CMD-SHELL", "pg_isready -U #{@postgres_user} -d #{@postgres_db}"],
        "Interval" => 2_000_000_000,
        "Timeout" => 5_000_000_000,
        "Retries" => 5
      }
    }

    with {:ok, %{"Id" => _id}} <-
           Client.post("/containers/create?name=#{@postgres_container}", body),
         {:ok, _} <- Client.post("/containers/#{@postgres_container}/start") do
      :ok
    else
      {:error, reason} -> {:error, {:postgres_create_failed, reason}}
    end
  end

  defp wait_for_postgres do
    Logger.info("Bootstrap: waiting for Postgres to accept connections...")
    do_wait_for_postgres(0)
  end

  defp do_wait_for_postgres(attempt) do
    if attempt >= wait_attempts() do
      {:error, :postgres_timeout}
    else
      case Client.get("/containers/#{@postgres_container}/json") do
        {:ok, %{"State" => %{"Health" => %{"Status" => "healthy"}}}} ->
          Logger.info("Bootstrap: Postgres is healthy")
          :ok

        _ ->
          Process.sleep(wait_interval_ms())
          do_wait_for_postgres(attempt + 1)
      end
    end
  end

  defp configure_repo(password) do
    container_host = @postgres_container

    repo_config = [
      username: @postgres_user,
      password: password,
      hostname: container_host,
      database: @postgres_db,
      port: 5432,
      pool_size: 10
    ]

    Application.put_env(:homelab, Homelab.Repo, repo_config)
    :ok
  end

  # --- Oban's dedicated Postgres instance (mirrors the app Postgres above) ----

  defp ensure_oban_postgres(password) do
    case Client.get("/containers/#{@oban_postgres_container}/json") do
      {:ok, %{"State" => %{"Running" => true}}} ->
        Logger.info("Bootstrap: Oban Postgres already running")
        :ok

      {:ok, %{"State" => %{"Running" => false}}} ->
        Logger.info("Bootstrap: starting existing Oban Postgres container")

        case Client.post("/containers/#{@oban_postgres_container}/start") do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:oban_postgres_start_failed, reason}}
        end

      {:error, {:not_found, _}} ->
        create_oban_postgres(password)

      {:error, reason} ->
        {:error, {:oban_postgres_check_failed, reason}}
    end
  end

  defp create_oban_postgres(password) do
    # Pull explicitly: the app DB now runs a different image, so this one is no
    # longer guaranteed to be present from create_postgres/1.
    Logger.info("Bootstrap: pulling #{@oban_postgres_image}...")

    _ =
      Client.post(
        "/images/create?fromImage=#{@oban_postgres_image_repo}&tag=#{@oban_postgres_image_tag}"
      )

    Logger.info("Bootstrap: creating Oban Postgres container")

    body = %{
      "Image" => @oban_postgres_image,
      "Env" => [
        "POSTGRES_USER=#{@postgres_user}",
        "POSTGRES_PASSWORD=#{password}",
        "POSTGRES_DB=#{@oban_postgres_db}"
      ],
      "HostConfig" => %{
        "NetworkMode" => @network,
        "Mounts" => [
          %{
            "Type" => "volume",
            "Source" => @oban_postgres_volume,
            "Target" => "/var/lib/postgresql/data"
          }
        ],
        "RestartPolicy" => %{"Name" => "unless-stopped"}
      },
      "Healthcheck" => %{
        "Test" => ["CMD-SHELL", "pg_isready -U #{@postgres_user} -d #{@oban_postgres_db}"],
        "Interval" => 2_000_000_000,
        "Timeout" => 5_000_000_000,
        "Retries" => 5
      }
    }

    with {:ok, %{"Id" => _id}} <-
           Client.post("/containers/create?name=#{@oban_postgres_container}", body),
         {:ok, _} <- Client.post("/containers/#{@oban_postgres_container}/start") do
      :ok
    else
      {:error, reason} -> {:error, {:oban_postgres_create_failed, reason}}
    end
  end

  defp wait_for_oban_postgres do
    Logger.info("Bootstrap: waiting for Oban Postgres to accept connections...")
    do_wait_for_oban_postgres(0)
  end

  defp do_wait_for_oban_postgres(attempt) do
    if attempt >= wait_attempts() do
      {:error, :oban_postgres_timeout}
    else
      case Client.get("/containers/#{@oban_postgres_container}/json") do
        {:ok, %{"State" => %{"Health" => %{"Status" => "healthy"}}}} ->
          Logger.info("Bootstrap: Oban Postgres is healthy")
          :ok

        _ ->
          Process.sleep(wait_interval_ms())
          do_wait_for_oban_postgres(attempt + 1)
      end
    end
  end

  defp configure_oban_repo(password) do
    oban_repo_config = [
      username: @postgres_user,
      password: password,
      hostname: @oban_postgres_container,
      database: @oban_postgres_db,
      port: 5432,
      pool_size: 6
    ]

    Application.put_env(:homelab, Homelab.ObanRepo, oban_repo_config)
    :ok
  end

  defp generate_password(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, length)
  end
end
