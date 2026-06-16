defmodule Homelab.Repo.Migrations.WorkbenchDataTrustFoundation do
  use Ecto.Migration

  def change do
    alter table(:system_settings) do
      add :vault_ref, :string
    end

    alter table(:backup_jobs) do
      add :tier, :string
      add :provider_driver_id, :string
      add :parent_job_id, references(:backup_jobs, on_delete: :nilify_all)
      add :target_ref, :map
      add :capture_metadata, :map
    end

    create index(:backup_jobs, [:tier])
    create index(:backup_jobs, [:parent_job_id])

    create table(:backup_schedules) do
      add :deployment_id, references(:deployments, on_delete: :delete_all), null: false
      add :tier, :string, null: false
      add :provider_driver_id, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :cadence_cron, :string
      add :target_ref, :map, null: false
      add :retention_policy, :map, default: %{}
      add :last_run_at, :utc_datetime

      timestamps()
    end

    create unique_index(:backup_schedules, [:deployment_id, :tier])
    create index(:backup_schedules, [:enabled])

    alter table(:deployments) do
      add :storage_backend, :string, null: false, default: "docker_volume"
      add :image_digest_pin, :string
      add :placement_affinity, :string, null: false, default: "any"
      add :pinned_node_id, :string
    end

    alter table(:app_templates) do
      add :consistency_mode, :string, null: false, default: "crash_consistent"
      add :pre_snapshot_cmd, :map
      add :post_snapshot_cmd, :map
    end

    create table(:storage_pools) do
      add :name, :string, null: false
      add :vdev, {:array, :string}, default: []
      add :options, :map, default: %{}
      add :health, :string, default: "unknown"
      add :imported_at, :utc_datetime

      timestamps()
    end

    create unique_index(:storage_pools, [:name])

    create table(:storage_datasets) do
      add :pool_id, references(:storage_pools, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :mountpoint, :string
      add :purpose, :string
      add :deployment_id, references(:deployments, on_delete: :nilify_all)

      timestamps()
    end

    create unique_index(:storage_datasets, [:name])
    create index(:storage_datasets, [:deployment_id])

    create table(:adopted_apps) do
      add :slug, :string, null: false
      add :source_path, :string, null: false
      add :size_bytes, :bigint
      add :classification, :string, null: false, default: "manual_only"
      add :has_compose, :boolean, default: false
      add :container_match, :map
      add :suggested_app_template_id, references(:app_templates, on_delete: :nilify_all)
      add :import_status, :string, null: false, default: "discovered"
      add :imported_at, :utc_datetime
      add :import_dataset, :string
      add :runbook_markdown, :string
      add :tenant_slug, :string

      timestamps()
    end

    create unique_index(:adopted_apps, [:source_path])
    create index(:adopted_apps, [:classification])
    create index(:adopted_apps, [:import_status])

    create table(:workbench_projects) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :slug, :string, null: false
      add :name, :string, null: false
      add :app_template_id, references(:app_templates, on_delete: :nilify_all)
      add :build_dataset, :string
      add :data_dataset, :string
      add :archived_at, :utc_datetime

      timestamps()
    end

    create unique_index(:workbench_projects, [:tenant_id, :slug])
    create index(:workbench_projects, [:archived_at])

    create table(:workbench_versions) do
      add :project_id, references(:workbench_projects, on_delete: :delete_all), null: false
      add :version_number, :integer, null: false
      add :snapshot_name, :string
      add :image_digest, :string, null: false
      add :image_tag, :string
      add :notes, :text
      add :published_at, :utc_datetime, null: false
      add :published_by, :string

      timestamps()
    end

    create unique_index(:workbench_versions, [:project_id, :version_number])

    create table(:workbench_builds) do
      add :project_id, references(:workbench_projects, on_delete: :delete_all), null: false
      add :version_id, references(:workbench_versions, on_delete: :nilify_all)
      add :status, :string, null: false, default: "pending"
      add :log, :text
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :error_message, :text

      timestamps()
    end

    create index(:workbench_builds, [:project_id])

    create table(:deployment_workbench_versions) do
      add :deployment_id, references(:deployments, on_delete: :delete_all), null: false

      add :workbench_version_id, references(:workbench_versions, on_delete: :delete_all),
        null: false

      timestamps()
    end

    create unique_index(:deployment_workbench_versions, [:deployment_id])

    create table(:nodes) do
      add :hostname, :string, null: false
      add :swarm_node_id, :string
      add :role, :string, null: false, default: "worker"
      add :site_label, :string, default: "primary"
      add :tunnel_address, :string
      add :status, :string, default: "unknown"
      add :last_heartbeat_at, :utc_datetime

      timestamps()
    end

    create unique_index(:nodes, [:hostname])

    create table(:node_datasets) do
      add :node_id, references(:nodes, on_delete: :delete_all), null: false
      add :dataset_name, :string, null: false
      add :role, :string, null: false, default: "primary"

      timestamps()
    end

    create unique_index(:node_datasets, [:node_id, :dataset_name])
  end
end
