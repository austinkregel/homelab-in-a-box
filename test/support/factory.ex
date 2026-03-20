defmodule Homelab.Factory do
  use ExMachina.Ecto, repo: Homelab.Repo

  def user_factory do
    %Homelab.Accounts.User{
      sub: sequence(:sub, &"oidc-sub-#{&1}"),
      email: sequence(:email, &"user#{&1}@test.local"),
      name: sequence(:name, &"User #{&1}"),
      role: :admin
    }
  end

  def tenant_factory do
    %Homelab.Tenants.Tenant{
      name: sequence(:name, &"Tenant #{&1}"),
      slug: sequence(:slug, &"tenant-#{&1}"),
      status: :active,
      settings: %{}
    }
  end

  def app_template_factory do
    %Homelab.Catalog.AppTemplate{
      slug: sequence(:slug, &"app-#{&1}"),
      name: sequence(:name, &"App #{&1}"),
      description: "A test application",
      version: "1.0.0",
      image: "testapp:latest",
      exposure_mode: :sso_protected,
      auth_integration: true,
      default_env: %{"APP_ENV" => "production"},
      required_env: [],
      volumes: [%{"container_path" => "/data"}],
      ports: [%{"container" => 8080, "protocol" => "tcp"}],
      resource_limits: %{"memory_mb" => 256, "cpu_shares" => 512},
      backup_policy: %{"enabled" => true, "schedule" => "0 2 * * *", "paths" => ["/data"]},
      health_check: %{"path" => "/health", "interval" => 30},
      depends_on: []
    }
  end

  def deployment_factory do
    %Homelab.Deployments.Deployment{
      status: :pending,
      external_id: nil,
      domain: sequence(:domain, &"app-#{&1}.tenant.homelab.local"),
      env_overrides: %{},
      computed_spec: nil,
      tenant: build(:tenant),
      app_template: build(:app_template)
    }
  end

  def domain_factory do
    %Homelab.Networking.Domain{
      fqdn: sequence(:fqdn, &"app-#{&1}.tenant.homelab.local"),
      exposure_mode: :sso_protected,
      tls_status: :pending,
      tls_expires_at: nil,
      deployment: build(:deployment)
    }
  end

  def dns_zone_factory do
    %Homelab.Networking.DnsZone{
      name: sequence(:zone_name, &"zone-#{&1}.example.com"),
      provider: "manual",
      provider_zone_id: nil,
      sync_status: :pending,
      last_synced_at: nil
    }
  end

  def dns_record_factory do
    %Homelab.Networking.DnsRecord{
      name: sequence(:record_name, &"host-#{&1}"),
      type: "A",
      value: "192.168.1.10",
      ttl: 300,
      scope: :public,
      managed: true,
      provider_record_id: nil,
      dns_zone: build(:dns_zone)
    }
  end

  def backup_job_factory do
    %Homelab.Backups.BackupJob{
      status: :pending,
      scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
      started_at: nil,
      completed_at: nil,
      snapshot_id: nil,
      size_bytes: nil,
      error_message: nil,
      deployment: build(:deployment)
    }
  end

  def service_status_factory do
    %{
      id: sequence(:id, &"svc_#{&1}"),
      name: sequence(:name, &"homelab_tenant_app_#{&1}"),
      state: :running,
      replicas: 1,
      image: "testapp:latest",
      labels: %{
        "homelab.managed" => "true",
        "homelab.tenant" => "test-tenant",
        "homelab.app" => "test-app"
      }
    }
  end
end
