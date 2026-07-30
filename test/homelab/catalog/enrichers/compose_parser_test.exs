defmodule Homelab.Catalog.Enrichers.ComposeParserTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.Enrichers.ComposeParser

  @basic_compose """
  services:
    app:
      image: nginx:latest
      ports:
        - "8080:80"
      volumes:
        - ./data:/data
      environment:
        - APP_ENV=production
        - SECRET_KEY=mysecret
  """

  @compose_with_db """
  services:
    web:
      image: myapp:latest
      ports:
        - "3000:3000"
      depends_on:
        - db
    db:
      image: postgres:16
      ports:
        - "5432:5432"
  """

  @compose_map_env """
  services:
    app:
      image: myapp:latest
      environment:
        APP_ENV: production
        DB_HOST: localhost
        DB_PORT: 5432
  """

  @compose_map_ports """
  services:
    app:
      image: myapp:latest
      ports:
        - target: 80
          published: 8080
        - target: 443
          published: 8443
  """

  @compose_map_volumes """
  services:
    app:
      image: myapp:latest
      volumes:
        - type: bind
          source: ./data
          target: /app/data
        - type: volume
          source: logs
          target: /var/log
  """

  @compose_integer_ports """
  services:
    app:
      image: myapp:latest
      ports:
        - 8080
        - 3000
  """

  @compose_udp_ports """
  services:
    app:
      image: myapp:latest
      ports:
        - "27900:27900/udp"
        - "18710:18710/tcp"
        - "18715:18715"
        - "127.0.0.1:5353:53/udp"
        - target: 161
          published: 1610
          protocol: udp
  """

  @compose_host_ip_port """
  services:
    app:
      image: myapp:latest
      ports:
        - "127.0.0.1:8080:80"
  """

  @compose_protocol_port """
  services:
    app:
      image: myapp:latest
      ports:
        - "8080:80/tcp"
        - "9090:90/udp"
  """

  @compose_depends_on_map """
  services:
    app:
      image: myapp:latest
      depends_on:
        db:
          condition: service_healthy
        redis:
          condition: service_started
  """

  @compose_no_services """
  version: "3"
  networks:
    default:
      driver: bridge
  """

  @compose_all_db """
  services:
    postgres:
      image: postgres:16
    redis:
      image: redis:7
  """

  @compose_single_port """
  services:
    app:
      image: myapp:latest
      ports:
        - "80"
  """

  @compose_volume_absolute """
  services:
    app:
      image: myapp:latest
      volumes:
        - /var/data
  """

  @compose_volume_named """
  services:
    app:
      image: myapp:latest
      volumes:
        - mydata
  """

  @compose_env_no_value """
  services:
    app:
      image: myapp:latest
      environment:
        - SECRET_KEY
  """

  describe "parse/1" do
    test "extracts ports from compose" do
      {:ok, result} = ComposeParser.parse(@basic_compose)
      assert length(result.ports) > 0
      port = hd(result.ports)
      assert port["internal"] == "80"
      assert port["external"] == "8080"
    end

    test "extracts volumes from compose" do
      {:ok, result} = ComposeParser.parse(@basic_compose)
      assert length(result.volumes) > 0
      assert hd(result.volumes)["path"] == "/data"
    end

    test "extracts environment variables" do
      {:ok, result} = ComposeParser.parse(@basic_compose)
      keys = Enum.map(result.env, & &1["key"])
      assert "APP_ENV" in keys
      assert "SECRET_KEY" in keys
    end

    test "picks non-db service as primary" do
      {:ok, result} = ComposeParser.parse(@compose_with_db)
      assert hd(result.ports)["internal"] == "3000"
    end

    test "extracts depends_on" do
      {:ok, result} = ComposeParser.parse(@compose_with_db)
      assert "db" in result.depends_on
    end

    test "returns error for invalid YAML" do
      assert {:error, _} = ComposeParser.parse("invalid: [yaml: {broken")
    end

    test "parses map-style environment variables" do
      {:ok, result} = ComposeParser.parse(@compose_map_env)
      keys = Enum.map(result.env, & &1["key"])
      assert "APP_ENV" in keys
      assert "DB_HOST" in keys
      assert "DB_PORT" in keys
      db_port = Enum.find(result.env, &(&1["key"] == "DB_PORT"))
      assert db_port["value"] == "5432"
    end

    test "parses map-style ports" do
      {:ok, result} = ComposeParser.parse(@compose_map_ports)
      assert length(result.ports) == 2
      port = Enum.find(result.ports, &(&1["internal"] == "80"))
      assert port["external"] == "8080"
    end

    test "parses map-style volumes" do
      {:ok, result} = ComposeParser.parse(@compose_map_volumes)
      assert length(result.volumes) == 2
      paths = Enum.map(result.volumes, & &1["path"])
      assert "/app/data" in paths
      assert "/var/log" in paths
    end

    test "parses integer ports" do
      {:ok, result} = ComposeParser.parse(@compose_integer_ports)
      assert length(result.ports) == 2
      internals = Enum.map(result.ports, & &1["internal"])
      assert "8080" in internals
      assert "3000" in internals
    end

    test "keeps the /udp suffix instead of stripping it to a silently-wrong tcp port" do
      # The old regex strip left the port NUMBER intact and only lost the transport, so
      # an imported UDP service looked correct everywhere and was simply unreachable.
      {:ok, result} = ComposeParser.parse(@compose_udp_ports)

      by_internal = Map.new(result.ports, &{&1["internal"], &1})

      assert by_internal["27900"]["protocol"] == "udp"
      assert by_internal["18710"]["protocol"] == "tcp"
      # Unsuffixed is tcp, matching compose's own default.
      assert by_internal["18715"]["protocol"] == "tcp"
      # host-ip form: the suffix still applies, and the ip is not mistaken for a port.
      assert by_internal["53"]["protocol"] == "udp"
      assert by_internal["53"]["external"] == "5353"
      # Long syntax carries protocol as its own key.
      assert by_internal["161"]["protocol"] == "udp"
      assert by_internal["161"]["external"] == "1610"
    end

    test "parses host-ip:external:internal port format, KEEPING the interface" do
      # The host IP used to be destructured away. `127.0.0.1:8080:80` is the operator
      # saying this is reachable from the host and nowhere else; dropping the interface
      # republished it on 0.0.0.0 — the whole LAN — and the imported result looked
      # identical, because only the interface changed.
      {:ok, result} = ComposeParser.parse(@compose_host_ip_port)
      port = hd(result.ports)
      assert port["internal"] == "80"
      assert port["external"] == "8080"
      assert port["host_ip"] == "127.0.0.1"
    end

    test "a port with no interface means all of them" do
      {:ok, result} = ComposeParser.parse(@basic_compose)
      assert hd(result.ports)["host_ip"] == nil
    end

    test "strips protocol from port strings" do
      {:ok, result} = ComposeParser.parse(@compose_protocol_port)
      assert length(result.ports) == 2
      port = Enum.find(result.ports, &(&1["internal"] == "80"))
      assert port["external"] == "8080"
    end

    test "parses depends_on as map with conditions" do
      {:ok, result} = ComposeParser.parse(@compose_depends_on_map)
      assert "db" in result.depends_on
      assert "redis" in result.depends_on
    end

    test "returns empty result for YAML with no services" do
      {:ok, result} = ComposeParser.parse(@compose_no_services)
      assert result.ports == []
      assert result.volumes == []
      assert result.env == []
      assert result.depends_on == []
    end

    test "falls back to first service when all are DB" do
      {:ok, result} = ComposeParser.parse(@compose_all_db)
      assert is_list(result.ports)
    end

    test "parses single port string" do
      {:ok, result} = ComposeParser.parse(@compose_single_port)
      port = hd(result.ports)
      assert port["internal"] == "80"
      assert port["external"] == "80"
    end

    test "parses absolute volume path" do
      {:ok, result} = ComposeParser.parse(@compose_volume_absolute)
      assert length(result.volumes) == 1
      assert hd(result.volumes)["path"] == "/var/data"
    end

    test "ignores named volumes without leading slash" do
      {:ok, result} = ComposeParser.parse(@compose_volume_named)
      assert result.volumes == []
    end

    test "env var without value gets empty string" do
      {:ok, result} = ComposeParser.parse(@compose_env_no_value)
      env = Enum.find(result.env, &(&1["key"] == "SECRET_KEY"))
      assert env["value"] == ""
    end
  end

  describe "parse_all/1" do
    test "returns all services" do
      {:ok, services} = ComposeParser.parse_all(@compose_with_db)
      assert length(services) == 2
      names = Enum.map(services, & &1.name)
      assert "web" in names
      assert "db" in names
    end

    test "each service has expected fields" do
      {:ok, services} = ComposeParser.parse_all(@compose_with_db)
      web = Enum.find(services, &(&1.name == "web"))
      assert is_list(web.ports)
      assert is_list(web.volumes)
      assert is_list(web.env)
      assert is_list(web.depends_on)
      assert web.image == "myapp:latest"
    end

    test "returns empty list for YAML without services" do
      {:ok, services} = ComposeParser.parse_all(@compose_no_services)
      assert services == []
    end

    test "returns error for invalid YAML" do
      assert {:error, _} = ComposeParser.parse_all("{{invalid")
    end
  end

  # Dropped silently until now. A compose file whose service needs NET_ADMIN and
  # /dev/net/tun imported CLEANLY and produced a template that could never work, with
  # nothing on screen to say why — the exact shape of every VPN-client stack.
  describe "kernel privileges" do
    @compose_gluetun """
    services:
      gluetun:
        image: qmcgaw/gluetun
        cap_add:
          - NET_ADMIN
        cap_drop:
          - CAP_SYS_MODULE
        devices:
          - /dev/net/tun:/dev/net/tun
        sysctls:
          - net.ipv4.conf.all.src_valid_mark=1
        restart: unless-stopped
    """

    test "cap_add and cap_drop are read, in either spelling" do
      {:ok, metadata} = ComposeParser.parse(@compose_gluetun)

      assert metadata.capabilities_add == ["NET_ADMIN"]
      assert metadata.capabilities_drop == ["SYS_MODULE"]
    end

    test "devices are read in compose's own spelling" do
      {:ok, metadata} = ComposeParser.parse(@compose_gluetun)

      assert metadata.devices == [
               %{
                 "host_path" => "/dev/net/tun",
                 "container_path" => "/dev/net/tun",
                 "permissions" => "rwm"
               }
             ]
    end

    test "sysctls are read in both the list and map forms" do
      {:ok, metadata} = ComposeParser.parse(@compose_gluetun)
      assert metadata.sysctls == %{"net.ipv4.conf.all.src_valid_mark" => "1"}

      map_form = """
      services:
        app:
          image: app:latest
          sysctls:
            net.core.somaxconn: 1024
      """

      {:ok, metadata} = ComposeParser.parse(map_form)
      assert metadata.sysctls == %{"net.core.somaxconn" => "1024"}
    end

    test "restart is read, and its retry-count suffix does not discard the whole policy" do
      {:ok, metadata} = ComposeParser.parse(@compose_gluetun)
      assert metadata.restart == "unless-stopped"

      with_count = """
      services:
        app:
          image: app:latest
          restart: on-failure:5
      """

      {:ok, metadata} = ComposeParser.parse(with_count)
      assert metadata.restart == "on-failure"
    end

    test "an unrecognised restart value is dropped rather than passed to the daemon" do
      {:ok, metadata} =
        ComposeParser.parse("""
        services:
          app:
            image: app:latest
            restart: sometimes
        """)

      assert metadata.restart == nil
    end

    test "command's exec form is kept verbatim; the shell form keeps its shell" do
      # Splitting `bundle exec rails s -b "0.0.0.0"` on whitespace gets the quoting
      # wrong. `/bin/sh -c <original>` preserves the semantics exactly instead.
      {:ok, metadata} =
        ComposeParser.parse("""
        services:
          app:
            image: app:latest
            command: ["minio", "server", "/data"]
        """)

      assert metadata.command == ["minio", "server", "/data"]

      {:ok, metadata} =
        ComposeParser.parse("""
        services:
          app:
            image: app:latest
            command: minio server /data
        """)

      assert metadata.command == ["/bin/sh", "-c", "minio server /data"]
    end

    test "a service declaring none of them yields empty values, not nil-in-a-list" do
      {:ok, metadata} = ComposeParser.parse(@basic_compose)

      assert metadata.capabilities_add == []
      assert metadata.capabilities_drop == []
      assert metadata.devices == []
      assert metadata.sysctls == %{}
      assert metadata.restart == nil
      assert metadata.command == nil
    end

    test "parse_all carries them per service" do
      {:ok, services} = ComposeParser.parse_all(@compose_gluetun)
      gluetun = Enum.find(services, &(&1.name == "gluetun"))

      assert gluetun.capabilities_add == ["NET_ADMIN"]
      assert [%{"host_path" => "/dev/net/tun"}] = gluetun.devices
    end
  end

  # `:ro` is not decoration. It is the operator saying this container must not write to
  # a media library, a config directory or a socket. The mode suffix was destructured
  # away as `_mode`, so every read-only mount was imported writable.
  describe "read-only mounts" do
    test "the :ro suffix survives the import" do
      {:ok, metadata} =
        ComposeParser.parse("""
        services:
          app:
            image: app:latest
            volumes:
              - /srv/media:/media:ro
              - /srv/data:/data
        """)

      [media, data] = metadata.volumes

      assert media["read_only"] == true
      assert data["read_only"] == false
    end

    test "a mode with several flags is still read-only" do
      # Compose allows `z,ro`, `ro,cached`, and so on.
      {:ok, metadata} =
        ComposeParser.parse("""
        services:
          app:
            image: app:latest
            volumes:
              - /srv/media:/media:z,ro
        """)

      assert [%{"read_only" => true}] = metadata.volumes
    end

    test "the long form's read_only is read too" do
      {:ok, metadata} =
        ComposeParser.parse("""
        services:
          app:
            image: app:latest
            volumes:
              - type: bind
                source: /srv/media
                target: /media
                read_only: true
        """)

      assert [%{"read_only" => true}] = metadata.volumes
    end
  end

  # The HOST side of a compose volume is where the data ALREADY IS. Dropping it (as this
  # parser used to) turns every folder mount in an imported stack into a fresh, empty
  # named volume — the app comes up with none of its data, and nothing says why.
  describe "volume host paths" do
    @compose_binds """
    services:
      app:
        image: app:latest
        volumes:
          - /srv/homelab/app/storage:/var/www/html/storage
          - ./data:/var/lib/app
          - pgdata:/var/lib/postgresql/data
          - /srv/homelab/app/conf:/etc/app:ro
    """

    test "an absolute host path is kept as a folder mount" do
      {:ok, result} = ComposeParser.parse(@compose_binds)
      vol = Enum.find(result.volumes, &(&1["path"] == "/var/www/html/storage"))

      assert vol["type"] == "bind"
      assert vol["source"] == "/srv/homelab/app/storage"
    end

    test "a :ro mode suffix does not eat the host path" do
      {:ok, result} = ComposeParser.parse(@compose_binds)
      vol = Enum.find(result.volumes, &(&1["path"] == "/etc/app"))

      assert vol["type"] == "bind"
      assert vol["source"] == "/srv/homelab/app/conf"
    end

    test "a relative host path resolves against the project dir, as compose does" do
      {:ok, result} = ComposeParser.parse(@compose_binds, project_dir: "/home/me/homelab")
      vol = Enum.find(result.volumes, &(&1["path"] == "/var/lib/app"))

      assert vol["type"] == "bind"
      assert vol["source"] == "/home/me/homelab/data"
    end

    test "without a project dir a relative path is carried through, NOT guessed" do
      {:ok, result} = ComposeParser.parse(@compose_binds)
      vol = Enum.find(result.volumes, &(&1["path"] == "/var/lib/app"))

      # It stays "./data" and fails validation downstream, which is the point: resolving
      # it against some arbitrary directory would mount a real folder holding nothing.
      assert vol["source"] == "./data"
    end

    test "a named volume is prefixed with the compose project name" do
      # `docker compose` names volumes <project>_<name>, and defaults <project> to the
      # basename of the project directory. Referencing the bare name would point at a
      # DIFFERENT, empty volume than the one the old stack has been writing to.
      {:ok, result} = ComposeParser.parse(@compose_binds, project_dir: "/home/me/homelab")
      vol = Enum.find(result.volumes, &(&1["path"] == "/var/lib/postgresql/data"))

      assert vol["type"] == "volume"
      assert vol["source"] == "homelab_pgdata"
    end

    test "long-form bind syntax keeps its source too" do
      compose = """
      services:
        app:
          image: app:latest
          volumes:
            - type: bind
              source: /srv/data
              target: /data
      """

      {:ok, result} = ComposeParser.parse(compose)
      vol = hd(result.volumes)

      assert vol["type"] == "bind"
      assert vol["source"] == "/srv/data"
      assert vol["path"] == "/data"
    end

    test "a bare container path stays an anonymous managed volume" do
      compose = """
      services:
        app:
          image: app:latest
          volumes:
            - /var/cache
      """

      {:ok, result} = ComposeParser.parse(compose)
      vol = hd(result.volumes)

      assert vol["type"] == "volume"
      assert vol["source"] == nil
    end
  end
end
