defmodule Homelab.Deployments.AdoptionPolicyTest do
  # async: false — pins the global :adoption_root so scope checks are deterministic.
  use ExUnit.Case, async: false

  alias Homelab.Deployments.AdoptionPolicy

  setup do
    Application.put_env(:homelab, :adoption_root, "/srv/homelab")
    Homelab.Settings.evict("adoption_root")

    on_exit(fn ->
      Application.delete_env(:homelab, :adoption_root)
      Homelab.Settings.evict("adoption_root")
    end)

    :ok
  end

  # Mounts as the discovery handler hands them over: %{source:, target:, type:}.
  defp bind(source, target), do: %{source: source, target: target, type: "bind"}
  defp vol(name, target), do: %{source: name, target: target, type: "volume"}

  describe "scope" do
    test "a service with a bind under the adoption root is in scope" do
      mounts = [bind("/srv/homelab/appdata/sonarr", "/config")]
      assert AdoptionPolicy.service_in_scope?("sonarr", mounts)
    end

    test "mariadb is in scope via its init-script bind even though its data is a named volume" do
      mounts = [
        bind(
          "/srv/homelab/scripts/create-mariadb-database.sh",
          "/docker-entrypoint-initdb.d/x.sh"
        ),
        vol("homelab_homelab-mariadb", "/var/lib/mysql")
      ]

      assert AdoptionPolicy.service_in_scope?("homelab-mariadb", mounts)
    end

    test "the plane's own infra is self-excluded even if a path matched" do
      mounts = [bind("/srv/homelab/whatever", "/x")]
      refute AdoptionPolicy.service_in_scope?("homelab-iab-postgres", mounts)
      refute AdoptionPolicy.service_in_scope?("homelab-in-a-box-postgres-1", mounts)
      refute AdoptionPolicy.service_in_scope?("homelab-traefik", mounts)
    end

    test "a named volume alone (no bind under root) is NOT in scope" do
      refute AdoptionPolicy.service_in_scope?("kratos-db", [
               vol("kratos_db-data", "/var/lib/postgresql/data")
             ])
    end

    test "Docker Desktop /host_mnt prefix is normalized for matching" do
      # adoption_root is the prod default; simulate a mac bind that maps under it.
      mounts = [bind("/host_mnt/srv/homelab/appdata/x", "/config")]
      assert AdoptionPolicy.service_in_scope?("x", mounts)
    end

    test "an unrelated dev project is out of scope" do
      refute AdoptionPolicy.service_in_scope?("marketplace-mysql-1", [
               bind("/host_mnt/srv/other/x.sh", "/init.sh"),
               vol("marketplace_sail-mysql", "/var/lib/mysql")
             ])
    end
  end

  describe "default is preserve" do
    test "an unclassified in-scope data dir is preserved" do
      m = bind("/srv/homelab/appdata/homelab-postgres", "/var/lib/postgresql/data")
      assert %{tier: :preserve} = AdoptionPolicy.classify_mount("homelab-postgres", m, [m])
    end

    test "gitlab data is preserved" do
      m = bind("/srv/homelab/appdata/gitlab/data", "/var/opt/gitlab")
      assert %{tier: :preserve} = AdoptionPolicy.classify_mount("gitlab", m, [m])
    end
  end

  describe "rebuildable rules" do
    test "plex /config is preserved but /transcode is rebuildable" do
      config = bind("/srv/homelab/appdata/plex", "/config")
      transcode = bind("/tmp", "/transcode")
      mounts = [config, transcode]

      assert %{tier: :preserve} = AdoptionPolicy.classify_mount("plex", config, mounts)
      assert %{tier: :rebuildable} = AdoptionPolicy.classify_mount("plex", transcode, mounts)
    end

    test "influxdb is entirely rebuildable (metric ingestion)" do
      data = %{source: "b375626d", target: "/var/lib/influxdb2", type: "volume"}
      mounts = [data, bind("/srv/homelab/appdata/influxdb/config", "/etc/influxdb")]
      assert %{tier: :rebuildable} = AdoptionPolicy.classify_mount("influxdb", data, mounts)
    end

    test "prometheus TSDB is rebuildable but its config dir is preserved" do
      tsdb = %{source: "245f1cb0", target: "/prometheus", type: "volume"}
      config = bind("/srv/homelab/appdata/prometheus", "/etc/prometheus")
      mounts = [tsdb, config]

      assert %{tier: :rebuildable} = AdoptionPolicy.classify_mount("prometheus", tsdb, mounts)
      assert %{tier: :preserve} = AdoptionPolicy.classify_mount("prometheus", config, mounts)
    end

    test "meilisearch is rebuildable AND reset_on_update" do
      data = bind("/srv/homelab/appdata/homelab-meilisearch", "/meili_data")

      assert %{tier: :rebuildable, reset_on_update: true} =
               AdoptionPolicy.classify_mount("homelab-meilisearch", data, [data])
    end

    test "model cache named volumes are rebuildable" do
      cache = vol("homelab_hf-cache", "/root/.cache/huggingface")
      anchor = bind("/srv/homelab/appdata/whisper/config", "/config")

      assert %{tier: :rebuildable} =
               AdoptionPolicy.classify_mount("wyoming-whisper", cache, [cache, anchor])
    end
  end

  describe "out of scope mounts" do
    test "classify as :out_of_scope even for a data-looking path" do
      m = vol("music-analysis_pgdata", "/var/lib/postgresql/data")
      assert %{tier: :out_of_scope} = AdoptionPolicy.classify_mount("music-analysis-db-1", m, [m])
    end
  end
end
