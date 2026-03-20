# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# This seeds the starter app catalog with curated, self-hosted apps.
# Safe to run multiple times — uses upsert on slug.

alias Homelab.Repo
alias Homelab.Catalog.AppTemplate

templates = [
  %{
    slug: "nextcloud",
    name: "Nextcloud",
    description:
      "Self-hosted file sync, sharing, and collaboration platform with office suite, calendar, contacts, and more.",
    version: "29.0",
    image: "nextcloud:29-apache",
    exposure_mode: :sso_protected,
    auth_integration: true,
    default_env: %{
      "NEXTCLOUD_ADMIN_USER" => "admin",
      "POSTGRES_HOST" => "db",
      "POSTGRES_DB" => "nextcloud",
      "OVERWRITEPROTOCOL" => "https"
    },
    required_env: ["NEXTCLOUD_ADMIN_PASSWORD", "POSTGRES_PASSWORD"],
    volumes: [
      %{"container_path" => "/var/www/html", "description" => "Nextcloud data and config"}
    ],
    ports: [%{"container" => 80, "protocol" => "tcp"}],
    resource_limits: %{"memory_mb" => 512, "cpu_shares" => 1024},
    backup_policy: %{
      "enabled" => true,
      "schedule" => "0 2 * * *",
      "paths" => ["/var/www/html/data"]
    },
    health_check: %{"path" => "/status.php", "interval" => 30, "timeout" => 10},
    depends_on: []
  },
  %{
    slug: "immich",
    name: "Immich",
    description:
      "High-performance self-hosted photo and video management. Google Photos alternative with ML-powered search.",
    version: "1.99",
    image: "ghcr.io/immich-app/immich-server:v1.99.0",
    exposure_mode: :sso_protected,
    auth_integration: true,
    default_env: %{
      "DB_HOSTNAME" => "db",
      "DB_DATABASE_NAME" => "immich",
      "DB_USERNAME" => "immich",
      "REDIS_HOSTNAME" => "redis"
    },
    required_env: ["DB_PASSWORD"],
    volumes: [
      %{"container_path" => "/usr/src/app/upload", "description" => "Photo/video uploads"}
    ],
    ports: [%{"container" => 3001, "protocol" => "tcp"}],
    resource_limits: %{"memory_mb" => 1024, "cpu_shares" => 2048},
    backup_policy: %{
      "enabled" => true,
      "schedule" => "0 3 * * *",
      "paths" => ["/usr/src/app/upload"]
    },
    health_check: %{"path" => "/api/server-info/ping", "interval" => 30, "timeout" => 10},
    depends_on: []
  },
  %{
    slug: "jellyfin",
    name: "Jellyfin",
    description:
      "Free media system for streaming movies, TV shows, music, and live TV. No premium needed.",
    version: "10.9",
    image: "jellyfin/jellyfin:10.9.11",
    exposure_mode: :sso_protected,
    auth_integration: true,
    default_env: %{
      "JELLYFIN_PublishedServerUrl" => ""
    },
    required_env: [],
    volumes: [
      %{"container_path" => "/config", "description" => "Jellyfin configuration"},
      %{"container_path" => "/media", "description" => "Media library"}
    ],
    ports: [%{"container" => 8096, "protocol" => "tcp"}],
    resource_limits: %{"memory_mb" => 1024, "cpu_shares" => 2048},
    backup_policy: %{"enabled" => true, "schedule" => "0 4 * * 0", "paths" => ["/config"]},
    health_check: %{"path" => "/health", "interval" => 30, "timeout" => 10},
    depends_on: []
  },
  %{
    slug: "vaultwarden",
    name: "Vaultwarden",
    description:
      "Lightweight Bitwarden-compatible password manager server. Secure credential sharing for your household.",
    version: "1.32",
    image: "vaultwarden/server:1.32.5",
    exposure_mode: :sso_protected,
    auth_integration: true,
    default_env: %{
      "DOMAIN" => "",
      "SIGNUPS_ALLOWED" => "false",
      "INVITATIONS_ALLOWED" => "true",
      "SHOW_PASSWORD_HINT" => "false"
    },
    required_env: ["ADMIN_TOKEN"],
    volumes: [
      %{"container_path" => "/data", "description" => "Vaultwarden database and attachments"}
    ],
    ports: [%{"container" => 80, "protocol" => "tcp"}],
    resource_limits: %{"memory_mb" => 256, "cpu_shares" => 512},
    backup_policy: %{"enabled" => true, "schedule" => "0 */6 * * *", "paths" => ["/data"]},
    health_check: %{"path" => "/alive", "interval" => 30, "timeout" => 5},
    depends_on: []
  },
  %{
    slug: "gitea",
    name: "Gitea",
    description:
      "Lightweight self-hosted Git service. Code hosting, code review, CI/CD, and package registry.",
    version: "1.22",
    image: "gitea/gitea:1.22",
    exposure_mode: :sso_protected,
    auth_integration: true,
    default_env: %{
      "GITEA__database__DB_TYPE" => "postgres",
      "GITEA__database__HOST" => "db:5432",
      "GITEA__database__NAME" => "gitea",
      "GITEA__server__ROOT_URL" => "",
      "GITEA__server__SSH_DOMAIN" => "",
      "GITEA__service__DISABLE_REGISTRATION" => "true"
    },
    required_env: ["GITEA__database__PASSWD"],
    volumes: [
      %{"container_path" => "/data", "description" => "Git repositories and Gitea data"}
    ],
    ports: [
      %{"container" => 3000, "protocol" => "tcp"},
      %{"container" => 22, "protocol" => "tcp", "description" => "SSH"}
    ],
    resource_limits: %{"memory_mb" => 512, "cpu_shares" => 1024},
    backup_policy: %{"enabled" => true, "schedule" => "0 2 * * *", "paths" => ["/data"]},
    health_check: %{"path" => "/api/healthz", "interval" => 30, "timeout" => 10},
    depends_on: []
  },
  %{
    slug: "uptime-kuma",
    name: "Uptime Kuma",
    description:
      "Fancy self-hosted monitoring tool. Monitor HTTP(s), TCP, Ping, DNS, and more with beautiful dashboards.",
    version: "1.23",
    image: "louislam/uptime-kuma:1.23",
    exposure_mode: :sso_protected,
    auth_integration: true,
    default_env: %{},
    required_env: [],
    volumes: [
      %{"container_path" => "/app/data", "description" => "Uptime Kuma database"}
    ],
    ports: [%{"container" => 3001, "protocol" => "tcp"}],
    resource_limits: %{"memory_mb" => 256, "cpu_shares" => 512},
    backup_policy: %{"enabled" => true, "schedule" => "0 3 * * 0", "paths" => ["/app/data"]},
    health_check: %{"path" => "/", "interval" => 60, "timeout" => 10},
    depends_on: []
  },
  %{
    slug: "paperless-ngx",
    name: "Paperless-ngx",
    description:
      "Document management system that transforms physical documents into a searchable online archive with OCR.",
    version: "2.7",
    image: "ghcr.io/paperless-ngx/paperless-ngx:2.7",
    exposure_mode: :sso_protected,
    auth_integration: true,
    default_env: %{
      "PAPERLESS_DBHOST" => "db",
      "PAPERLESS_DBNAME" => "paperless",
      "PAPERLESS_REDIS" => "redis://redis:6379",
      "PAPERLESS_OCR_LANGUAGE" => "eng"
    },
    required_env: ["PAPERLESS_DBPASS", "PAPERLESS_SECRET_KEY"],
    volumes: [
      %{"container_path" => "/usr/src/paperless/data", "description" => "Paperless database"},
      %{"container_path" => "/usr/src/paperless/media", "description" => "Document storage"},
      %{"container_path" => "/usr/src/paperless/consume", "description" => "Document inbox"}
    ],
    ports: [%{"container" => 8000, "protocol" => "tcp"}],
    resource_limits: %{"memory_mb" => 1024, "cpu_shares" => 1024},
    backup_policy: %{
      "enabled" => true,
      "schedule" => "0 2 * * *",
      "paths" => ["/usr/src/paperless/data", "/usr/src/paperless/media"]
    },
    health_check: %{"path" => "/api/", "interval" => 30, "timeout" => 10},
    depends_on: []
  },
  %{
    slug: "mealie",
    name: "Mealie",
    description:
      "Self-hosted recipe manager and meal planner with a beautiful UI, shopping lists, and household management.",
    version: "1.12",
    image: "ghcr.io/mealie-recipes/mealie:v1.12.0",
    exposure_mode: :sso_protected,
    auth_integration: true,
    default_env: %{
      "ALLOW_SIGNUP" => "false",
      "DB_ENGINE" => "postgres",
      "POSTGRES_SERVER" => "db",
      "POSTGRES_DB" => "mealie"
    },
    required_env: ["POSTGRES_PASSWORD"],
    volumes: [
      %{"container_path" => "/app/data", "description" => "Mealie data and uploads"}
    ],
    ports: [%{"container" => 9000, "protocol" => "tcp"}],
    resource_limits: %{"memory_mb" => 512, "cpu_shares" => 512},
    backup_policy: %{"enabled" => true, "schedule" => "0 3 * * *", "paths" => ["/app/data"]},
    health_check: %{"path" => "/api/app/about", "interval" => 30, "timeout" => 10},
    depends_on: []
  },
  %{
    slug: "wireguard",
    name: "WireGuard",
    description:
      "Fast, modern VPN tunnel. Securely access your homelab from anywhere with minimal overhead.",
    version: "1.0",
    image: "lscr.io/linuxserver/wireguard:latest",
    exposure_mode: :private,
    auth_integration: false,
    default_env: %{
      "PUID" => "1000",
      "PGID" => "1000",
      "TZ" => "America/New_York",
      "PEERS" => "5",
      "PEERDNS" => "auto",
      "INTERNAL_SUBNET" => "10.13.13.0"
    },
    required_env: ["SERVERURL"],
    volumes: [
      %{"container_path" => "/config", "description" => "WireGuard configuration and peer keys"}
    ],
    ports: [%{"container" => 51820, "protocol" => "udp"}],
    resource_limits: %{"memory_mb" => 128, "cpu_shares" => 256},
    backup_policy: %{"enabled" => true, "schedule" => "0 4 * * 0", "paths" => ["/config"]},
    health_check: %{"path" => "", "interval" => 60, "timeout" => 10},
    depends_on: []
  },
  %{
    slug: "freshrss",
    name: "FreshRSS",
    description:
      "Lightweight, self-hosted RSS feed aggregator. Follow news, blogs, and podcasts in one place.",
    version: "1.24",
    image: "freshrss/freshrss:1.24",
    exposure_mode: :sso_protected,
    auth_integration: true,
    default_env: %{
      "CRON_MIN" => "1,31",
      "TZ" => "America/New_York"
    },
    required_env: [],
    volumes: [
      %{"container_path" => "/var/www/FreshRSS/data", "description" => "FreshRSS data"},
      %{
        "container_path" => "/var/www/FreshRSS/extensions",
        "description" => "FreshRSS extensions"
      }
    ],
    ports: [%{"container" => 80, "protocol" => "tcp"}],
    resource_limits: %{"memory_mb" => 256, "cpu_shares" => 256},
    backup_policy: %{
      "enabled" => true,
      "schedule" => "0 4 * * 0",
      "paths" => ["/var/www/FreshRSS/data"]
    },
    health_check: %{"path" => "/i/", "interval" => 60, "timeout" => 10},
    depends_on: []
  }
]

for attrs <- templates do
  case Repo.get_by(AppTemplate, slug: attrs.slug) do
    nil ->
      %AppTemplate{}
      |> AppTemplate.changeset(attrs)
      |> Repo.insert!()

      IO.puts("  Created app template: #{attrs.name}")

    existing ->
      existing
      |> AppTemplate.changeset(attrs)
      |> Repo.update!()

      IO.puts("  Updated app template: #{attrs.name}")
  end
end

IO.puts("\nSeed complete! #{length(templates)} app templates loaded.")
