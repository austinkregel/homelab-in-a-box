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
  the adoption root** (default `/home/austinkregel/homelab`), AND its name is not
  in the self-exclusion list. Path matching normalizes Docker Desktop's
  `/host_mnt` prefix so it works on both the Linux prod host and a macOS dev box.

  We deliberately do NOT use volume-name prefixes for scope: names collide
  (`homelab-iab-*` is the plane's own DB, `homelab-development-*` is a dev
  project), whereas "has a bind under the homelab root" cleanly separates the
  real stack — including the MariaDB whose only in-root mount is its init script —
  from both the plane's own infra and unrelated projects.

  All assignments below are intended to be reviewed and edited — they encode
  current decisions, not immutable truth.
  """

  @adoption_root_default "/home/austinkregel/homelab"
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

  @type tier :: :preserve | :rebuildable | :out_of_scope
  @type classification :: %{tier: tier(), reset_on_update: boolean()}

  @doc """
  The host root that delimits in-scope data. Resolution order: a UI override
  (Settings `adoption_root`, read cache-only), then the `HOMELAB_ADOPTION_ROOT`
  env var (via app config), then the built-in default.
  """
  def adoption_root do
    Homelab.Settings.get_cached("adoption_root") ||
      Application.get_env(:homelab, :adoption_root) ||
      @adoption_root_default
  end

  @doc """
  True if a service (its name + list of mounts) belongs to this homelab and is
  therefore a candidate for adoption. A mount is `%{source:, target:, type:}`.
  """
  def service_in_scope?(service_name, mounts) when is_list(mounts) do
    not self_excluded?(service_name) and Enum.any?(mounts, &bind_under_root?/1)
  end

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
  @spec classify_mount(String.t(), map(), [map()]) :: classification()
  def classify_mount(service_name, mount, service_mounts) do
    cond do
      not service_in_scope?(service_name, service_mounts) ->
        %{tier: :out_of_scope, reset_on_update: false}

      rule = matching_rule(service_name, mount) ->
        %{tier: :rebuildable, reset_on_update: Map.get(rule, :reset_on_update, false)}

      rebuildable_volume?(mount) ->
        %{tier: :rebuildable, reset_on_update: false}

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
end
