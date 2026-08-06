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

  describe "an unconfigured adoption root on a containerized install" do
    setup do
      Application.delete_env(:homelab, :adoption_root)
      Homelab.Settings.evict("adoption_root")
      Application.put_env(:homelab, :containerized, true)
      on_exit(fn -> Application.delete_env(:homelab, :containerized) end)
      :ok
    end

    # Same shape as `PermanentHome.managed_root/0`: `~/homelab` is `/root/homelab` inside
    # this container, and it is compared against the HOST paths Docker reports. It can
    # never match, so every scan read as "you have nothing to import".
    test "refuses rather than falling back to a container-local path" do
      assert {:error, :adoption_root_unconfigured} = AdoptionPolicy.fetch_adoption_root()

      assert_raise ArgumentError, ~r/adoption root is not configured/, fn ->
        AdoptionPolicy.adoption_root()
      end
    end

    test "the refusal names the setting and the env var an operator can fix it with" do
      message = AdoptionPolicy.unconfigured_message()
      assert message =~ "HOMELAB_ADOPTION_ROOT"
      assert message =~ "Settings -> Import"
      assert message =~ "/root/homelab"
    end

    # The planner is the ONE caller that must not blow up: it is what the Import screen
    # calls, and the screen's job is to explain this exact problem.
    test "AdoptionPlanner.review/0 reports it instead of raising out of scope checks" do
      assert {:error, :adoption_root_unconfigured} =
               Homelab.Deployments.AdoptionPlanner.review()
    end

    test "a configured root is still honoured" do
      Application.put_env(:homelab, :adoption_root, "/srv/homelab")
      on_exit(fn -> Application.delete_env(:homelab, :adoption_root) end)

      assert {:ok, "/srv/homelab"} = AdoptionPolicy.fetch_adoption_root()
      assert AdoptionPolicy.service_in_scope?("sonarr", [
               %{source: "/srv/homelab/appdata/sonarr", target: "/config", type: "bind"}
             ])
    end
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

  # An ADOPTED container is the adversarial case: it keeps the ORIGINAL name and mounts
  # the ORIGINAL bind under the adoption root, so it passes every scope test there is.
  # The label is the only thing that says "this one is already ours".
  describe "already-managed containers are never re-adopted" do
    @managed %{"homelab.managed" => "true"}

    test "a container we deployed is out of scope despite a bind under the root" do
      mounts = [bind("/srv/homelab/appdata/sonarr", "/config")]

      # Same name, same mounts — only the label differs.
      assert AdoptionPolicy.service_in_scope?("sonarr", mounts)
      refute AdoptionPolicy.service_in_scope?("sonarr", mounts, @managed)
    end

    test "an adopted container keeps its original name, so the name list cannot catch it" do
      mounts = [bind("/srv/homelab/appdata/pg", "/var/lib/postgresql/data")]

      labels = Map.merge(@managed, %{"homelab.adopted" => "true"})

      refute AdoptionPolicy.service_in_scope?("homelab-postgres", mounts, labels)
    end

    test "its mounts classify as out_of_scope, so no backup gate or sweep applies" do
      m = bind("/srv/homelab/appdata/pg", "/var/lib/postgresql/data")

      assert %{tier: :out_of_scope} =
               AdoptionPolicy.classify_mount("homelab-postgres", m, [m], @managed)
    end

    test "already_managed? keys off the label we stamp, not the name" do
      assert AdoptionPolicy.already_managed?(@managed)
      refute AdoptionPolicy.already_managed?(%{"homelab.managed" => "false"})
      refute AdoptionPolicy.already_managed?(%{"com.docker.compose.project" => "homelab"})
      refute AdoptionPolicy.already_managed?(%{})
      refute AdoptionPolicy.already_managed?(nil)
    end

    test "no labels at all is treated as unmanaged — the old stack has none" do
      mounts = [bind("/srv/homelab/appdata/sonarr", "/config")]
      assert AdoptionPolicy.service_in_scope?("sonarr", mounts, %{})
    end
  end

  # Scope is decided per SERVICE — one bind under the adoption root pulls the whole
  # container in — and every mount on it was then classified against that single verdict.
  # So a media library, a NAS share, a second disk: anything the container also mounts got
  # `:preserve`, which is the tier that feeds the backup gate and the migrate copy.
  #
  # Reported from production: an import stalled trying to back up `/media/Music`, a Samba
  # share on a NAS. Under `:migrate` the next step would have been copying it into the
  # managed home.
  describe "mounts outside the adoption root" do
    test "a NAS share on an otherwise in-scope service is external, not preserved" do
      config = bind("/srv/homelab/appdata/navidrome", "/config")
      music = bind("/media/Music", "/music")
      mounts = [config, music]

      assert %{tier: :preserve} = AdoptionPolicy.classify_mount("navidrome", config, mounts)
      assert %{tier: :external} = AdoptionPolicy.classify_mount("navidrome", music, mounts)
    end

    test "a second disk is external even when the service is squarely in scope" do
      config = bind("/srv/homelab/appdata/plex", "/config")
      media = bind("/mnt/storage/movies", "/movies")

      assert %{tier: :external} =
               AdoptionPolicy.classify_mount("plex", media, [config, media])
    end

    # The root itself and anything under it stays managed — this must not become a blanket
    # "anything unusual is external" rule, or adoption stops adopting.
    test "a nested path under the root is still preserved" do
      m = bind("/srv/homelab/appdata/deep/nested/data", "/data")
      assert %{tier: :preserve} = AdoptionPolicy.classify_mount("app", m, [m])
    end

    # A named volume has no host path to be on another drive; the daemon owns where it
    # lives. Classifying those as external would strip every ordinary docker volume out of
    # adoption.
    test "a named volume is never external" do
      config = bind("/srv/homelab/appdata/app", "/config")
      data = vol("app_data", "/data")

      refute match?(
               %{tier: :external},
               AdoptionPolicy.classify_mount("app", data, [config, data])
             )
    end

    # An out-of-scope SERVICE is still out of scope — external is about a mount on a
    # service we are adopting, not a way in for one we are not.
    test "a service with no in-scope bind at all stays out_of_scope" do
      music = bind("/media/Music", "/music")

      assert %{tier: :out_of_scope} = AdoptionPolicy.classify_mount("navidrome", music, [music])
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
