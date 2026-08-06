defmodule Homelab.Deployments.AdoptionPolicy do
  @moduledoc """
  Classifies the data of an existing (to-be-adopted) container by **criticality
  tier**, which drives how the adoption saga treats each mount.

  This module is deliberately **secret-free** — it holds only `path -> tier`
  knowledge, so it is safe to keep versioned in the repo. Actual credentials live
  in the encrypted secret store (`Homelab.Crypto` + `deployment_secret`) and are
  *imported*, never inlined here.

  ## Tiers

    * `:preserve` — irreplaceable state. The backup-first gate is **mandatory**
      before any cutover, and the reconciler must **never** reap it. This is the
      DEFAULT: anything in scope we have not explicitly classified is preserved.
    * `:rebuildable` — best-effort. Repopulates itself (metric ingestion, model
      caches, search indexes). No backup gate; the reconciler may reap it.
    * `:out_of_scope` — not part of this homelab. Present on the daemon but
      transient/dev, or the plane's OWN infrastructure. The plane must neither
      adopt, back up, **nor sweep** these — they are invisible to it.

  A `:rebuildable` mount may additionally carry `reset_on_update: true`, meaning
  its volume is **wiped on every update** rather than merely allowed to be reaped
  (Meilisearch breaks across version bumps unless its index is recreated).

  ## Scope

  In-scope = the service has at least one **bind mount whose host path is under
  the adoption root** (default `<home>/homelab`, i.e. `~/homelab`; override with
  `HOMELAB_ADOPTION_ROOT` or Settings → Infrastructure), AND its name is not in
  the self-exclusion list, AND it is not **already managed by us**. Path matching
  normalizes Docker Desktop's `/host_mnt` prefix so it works on both the Linux
  prod host and a macOS dev box.

  The already-managed check reads the `homelab.managed=true` label `SpecBuilder`
  stamps on everything we deploy. It is not redundant with the name-based
  self-exclusion list: an **adopted** container keeps serving the ORIGINAL data
  from the ORIGINAL bind under the adoption root, under a name we did not choose
  — so it matches the in-scope test perfectly and would be offered for adoption
  again, forever. Adopting an already-adopted container would quiesce and cut over
  a container the plane itself is running.

  We deliberately do NOT use volume-name prefixes for scope: names collide
  (`homelab-iab-*` is the plane's own DB, `homelab-development-*` is a dev
  project), whereas "has a bind under the homelab root" cleanly separates the
  real stack — including the MariaDB whose only in-root mount is its init script —
  from both the plane's own infra and unrelated projects.

  All assignments below are intended to be reviewed and edited — they encode
  current decisions, not immutable truth.
  """

  @host_mount_prefixes ["/host_mnt"]

  # The plane's OWN containers — never candidates for adoption (it manages
  # itself). Matched as case-insensitive substrings of the container name.
  @self_excluded_patterns ~w(homelab-iab homelab-in-a-box homelab-traefik)

  # Per-(service, container_path) overrides off the `:preserve` default. `service`
  # is matched as a case-insensitive substring of the container name, so
  # "alert-manager" matches "homelab-alert-manager-1". `path` is `:all`, an exact
  # container path, or `{:prefix, "/p"}`.
  @rebuildable_rules [
    # Metric ingestion / time-series — disposable, repopulates on its own.
    %{service: "influxdb", path: :all},
    %{service: "prometheus", path: "/prometheus"},
    %{service: "alert-manager", path: "/alertmanager"},
    # Model / inference caches — re-pullable.
    %{service: "ollama", path: "/root/.ollama"},
    %{service: "whisper", path: {:prefix, "/data"}},
    # Search index — reindexes from source DBs; MUST be wiped on update.
    %{service: "meilisearch", path: "/meili_data", reset_on_update: true},
    # Misc rebuildable caches / scratch.
    %{service: "flaresolverr", path: "/config"},
    %{service: "gitlab-runner", path: "/home/gitlab-runner"},
    %{service: "esphome", path: "/root/.platformio"},
    %{service: "plex", path: "/transcode"},
    %{service: "mailpit", path: "/data"}
  ]

  # Named volumes that are pure caches regardless of which service mounts them.
  @rebuildable_volume_names ~w(
    homelab_hf-cache homelab_piper-data homelab_openwakeword-data homelab_whisper-data
  )

  @type tier :: :preserve | :rebuildable | :external | :out_of_scope
  @type classification :: %{tier: tier(), reset_on_update: boolean()}

  @unconfigured_message """
  The adoption root is not configured, and this instance is running in a container.

  There is no safe default here. `~/homelab` resolves to `/root/homelab` INSIDE this
  container, while the paths it is matched against are the HOST paths Docker reports for
  bind mounts — so discovery would silently match nothing and every scan would read as
  "you have nothing to import" rather than "you are looking in the wrong place".

  Set it in Settings -> Import ("Adoption root"), or with the HOMELAB_ADOPTION_ROOT
  environment variable. It must be an absolute HOST path.
  """

  @doc """
  The host root that delimits in-scope data, or
  `{:error, :adoption_root_unconfigured}` when it is unset on a containerized
  install. Non-raising counterpart of `adoption_root/0`.

  Resolution order: a UI override (Settings `adoption_root`, read cache-only),
  then the `HOMELAB_ADOPTION_ROOT` env var (via app config), then — only when the
  plane is NOT containerized — a runtime default of `~/homelab`.
  """
  def fetch_adoption_root do
    configured =
      Homelab.Settings.get_cached("adoption_root") ||
        Application.get_env(:homelab, :adoption_root)

    cond do
      is_binary(configured) and configured != "" -> {:ok, configured}
      Homelab.Infrastructure.containerized?() -> {:error, :adoption_root_unconfigured}
      true -> {:ok, default_root("homelab")}
    end
  end

  @doc """
  The host root that delimits in-scope data.

  Raises when unconfigured on a containerized install. Same argument as
  `PermanentHome.managed_root/0`: a `System.user_home()` default is a path inside
  the container, and it is then compared against (or handed to the daemon as) a
  path on the host. The two are unrelated directories that share a name.
  """
  def adoption_root do
    case fetch_adoption_root() do
      {:ok, root} -> root
      {:error, :adoption_root_unconfigured} -> raise ArgumentError, @unconfigured_message
    end
  end

  @doc "The operator-facing explanation of an unconfigured adoption root."
  def unconfigured_message, do: @unconfigured_message

  # A person-agnostic default derived at runtime: the current user's home +
  # `homelab` (i.e. `~/homelab`). Only reachable when NOT containerized — see
  # `fetch_adoption_root/0`.
  defp default_root(suffix), do: Path.join(System.user_home() || "/root", suffix)

  @doc """
  True if a service (its name + mounts + container labels) belongs to this homelab
  and is therefore a candidate for adoption. A mount is `%{source:, target:, type:}`.
  """
  def service_in_scope?(service_name, mounts, labels \\ %{}) when is_list(mounts) do
    not already_managed?(labels) and not self_excluded?(service_name) and
      Enum.any?(mounts, &bind_under_root?/1)
  end

  @doc """
  True if this container is one WE deployed — it carries the `homelab.managed`
  label `SpecBuilder` stamps on every spec it builds.

  This is the only reliable signal for an adopted container: it keeps the original
  name and the original bind mounts, so nothing about its shape distinguishes it
  from the unmanaged container it replaced.
  """
  def already_managed?(labels) when is_map(labels),
    do: Map.get(labels, "homelab.managed") == "true"

  def already_managed?(_labels), do: false

  defp self_excluded?(name) do
    down = String.downcase(name || "")
    Enum.any?(@self_excluded_patterns, &String.contains?(down, &1))
  end

  defp bind_under_root?(%{type: "bind", source: source}) when is_binary(source) do
    norm = strip_host_mount(source)
    root = adoption_root()
    norm == root or String.starts_with?(norm, root <> "/")
  end

  defp bind_under_root?(_), do: false

  @doc """
  Strips Docker Desktop's `/host_mnt` prefix, yielding the path as it exists on the
  HOST (and therefore as the plane sees it, when the host path is mounted in).

  This is not only a scope-matching concern. The backup and copy engines `File.cp_r`
  the target path from inside the plane's own container, so a `/host_mnt/...` path
  handed to them is unreadable — it exists neither on the host nor in the container.
  Every path that leaves discovery for a filesystem operation must come through here.
  """
  def normalize_host_path(path) when is_binary(path), do: strip_host_mount(path)
  def normalize_host_path(path), do: path

  defp strip_host_mount(path) do
    Enum.reduce_while(@host_mount_prefixes, path, fn prefix, acc ->
      if String.starts_with?(acc, prefix <> "/"),
        do: {:halt, String.replace_prefix(acc, prefix, "")},
        else: {:cont, acc}
    end)
  end

  @doc """
  Classifies one mount of a service. Returns `%{tier:, reset_on_update:}`.

  Out-of-scope services classify every mount as `:out_of_scope`. In-scope mounts
  default to `:preserve` unless a rebuildable rule (by service+path) or a
  rebuildable volume name matches.
  """
  @spec classify_mount(String.t(), map(), [map()], map()) :: classification()
  def classify_mount(service_name, mount, service_mounts, labels \\ %{}) do
    tier_for(service_name, mount, service_in_scope?(service_name, service_mounts, labels))
  end

  @doc """
  Classifies one mount given an ALREADY-DECIDED scope verdict.

  Scope is not always a property of the container alone: a compose sibling is in scope
  because a *different* container in its project has a bind under the adoption root
  (see `AdoptionDiscovery.expand_compose_scope/1`). Such a service cannot re-derive its
  own verdict from its own mounts, so it is handed the answer.
  """
  @spec tier_for(String.t(), map(), boolean()) :: classification()
  def tier_for(service_name, mount, in_scope?) do
    cond do
      not in_scope? ->
        %{tier: :out_of_scope, reset_on_update: false}

      rule = matching_rule(service_name, mount) ->
        %{tier: :rebuildable, reset_on_update: Map.get(rule, :reset_on_update, false)}

      rebuildable_volume?(mount) ->
        %{tier: :rebuildable, reset_on_update: false}

      # AFTER the rebuildable checks, deliberately. A known scratch path is a statement
      # about the NATURE of the data — regenerable, do not carry it over — and that is
      # both more specific and more useful than "it is not under my root". Plex's
      # transcode dir is `/tmp`: outside the root, and still something to recreate rather
      # than bind the host's `/tmp` into the replacement.
      external_bind?(mount) ->
        %{tier: :external, reset_on_update: false}

      true ->
        %{tier: :preserve, reset_on_update: false}
    end
  end

  defp matching_rule(service_name, mount) do
    container_path = mount[:target] || mount["Destination"]
    name = String.downcase(service_name || "")

    Enum.find(@rebuildable_rules, fn rule ->
      String.contains?(name, rule.service) and path_matches?(rule.path, container_path)
    end)
  end

  defp path_matches?(:all, _path), do: true
  defp path_matches?(_pattern, nil), do: false
  defp path_matches?({:prefix, prefix}, path), do: String.starts_with?(path, prefix)
  defp path_matches?(exact, path) when is_binary(exact), do: exact == path

  defp rebuildable_volume?(%{source: source}) when is_binary(source),
    do: source in @rebuildable_volume_names

  defp rebuildable_volume?(_), do: false

  # A bind whose host source is NOT under the adoption root: a media library on a second
  # disk, a NAS export, a share the operator mounts for several stacks.
  #
  # Scope is a SERVICE-level verdict — one bind under the root pulls the whole container
  # in — and every mount was then classified against that single answer. So a container
  # with `appdata/navidrome` AND `/media/Music` had both marked `:preserve`, which is the
  # tier that feeds `BackupVerify` and `MigrateCopy`. An import stalled trying to back up
  # a Samba share; under `:migrate` the step after that would have copied the whole
  # library into the managed home.
  #
  # These mounts are still MOUNTED — the app needs them — but they are not this plane's
  # data to copy, checksum, or take a permanent home for. `AdoptionPlanner` binds them
  # through in place at their original path regardless of strategy.
  #
  # Only binds. A named volume has no host path that could be on another drive; the
  # daemon decides where it lives, and calling those external would strip every ordinary
  # docker volume out of adoption.
  defp external_bind?(%{type: "bind"} = mount), do: not bind_under_root?(mount)
  defp external_bind?(_mount), do: false
end
