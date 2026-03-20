defmodule Homelab.Bootstrap do
  @moduledoc """
  Self-bootstrapping infrastructure provisioner.

  When running inside a Docker container with the host's Docker socket
  mounted, this module ensures Postgres is running before the Repo starts.
  In development mode (when Postgres config is already provided), it's a no-op.
  """

  require Logger

  alias Homelab.Docker.Client

  @postgres_container "homelab-postgres"
  @postgres_volume "homelab-postgres-data"
  @secrets_volume "homelab-secrets"
  @network "homelab-internal"
  @postgres_image "postgres:17-alpine"
  @postgres_user "homelab"
  @postgres_db "homelab_prod"
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
           :ok <- configure_repo(password) do
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
      Homelab.Settings.mark_setup_completed()
      Logger.info("Bootstrap: setup seeded and marked complete")
    end
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

  defp ensure_network do
    case Client.get("/networks/#{@network}") do
      {:ok, _} ->
        :ok

      {:error, {:not_found, _}} ->
        Logger.info("Bootstrap: creating network #{@network}")

        case Client.post("/networks/create", %{"Name" => @network, "Driver" => "bridge"}) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:network_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:network_check_failed, reason}}
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

  defp do_wait_for_tcp(attempt) when attempt >= @max_wait_attempts do
    {:error, :postgres_tcp_timeout}
  end

  defp do_wait_for_tcp(attempt) do
    case :gen_tcp.connect(~c"#{@postgres_container}", 5432, [], 2_000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        Logger.info("Bootstrap: TCP connection to Postgres confirmed")
        :ok

      {:error, _} ->
        Process.sleep(@wait_interval_ms)
        do_wait_for_tcp(attempt + 1)
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
    _ = Client.post("/images/create?fromImage=postgres&tag=17-alpine")

    Logger.info("Bootstrap: creating Postgres container")

    body = %{
      "Image" => @postgres_image,
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

  defp do_wait_for_postgres(attempt) when attempt >= @max_wait_attempts do
    {:error, :postgres_timeout}
  end

  defp do_wait_for_postgres(attempt) do
    case Client.get("/containers/#{@postgres_container}/json") do
      {:ok, %{"State" => %{"Health" => %{"Status" => "healthy"}}}} ->
        Logger.info("Bootstrap: Postgres is healthy")
        :ok

      {:ok, %{"State" => %{"Running" => true}}} ->
        Process.sleep(@wait_interval_ms)
        do_wait_for_postgres(attempt + 1)

      _ ->
        Process.sleep(@wait_interval_ms)
        do_wait_for_postgres(attempt + 1)
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

  defp generate_password(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, length)
  end
end
