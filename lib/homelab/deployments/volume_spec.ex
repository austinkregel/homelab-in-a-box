defmodule Homelab.Deployments.VolumeSpec do
  @moduledoc """
  The one definition of what a volume is.

  A volume is either:

    * **managed** (`type: "volume"`) — Docker owns a named volume. `source` is the
      volume's NAME, or blank, in which case `SpecBuilder` derives one from the mount
      path (`homelab-<tenant>-<app>-<path>`).

    * **bind** (`type: "bind"`) — a host directory the operator already owns, mounted
      into the container. `source` is an absolute path on the HOST. The pre-homelab
      stack is entirely folder mounts, so adopting or matching it is impossible
      without these.

  Either kind may additionally be **borrowed** (`borrowed: true`) -- a named volume whose
  data belongs to another deployment, mounted here so one library can serve several apps.
  Docker has no such distinction, so `mark_borrowed/3` decides it when a mount is made and
  every producer carries the answer from there; see the key's comment in `normalize/1`.

  Every producer of a volume map (the deploy wizard, the compose parser, the adoption
  planner, the post-deploy Volumes tab) normalizes through here, and both schemas that
  persist one (`AppTemplate.volumes`, `Deployment.volumes_override`) validate through
  here. Before this module each producer invented its own shape, and the ones that
  forgot `type`/`source` silently downgraded a folder mount to an empty named volume.

  ## Kinds

  The two editors — the deploy wizard and the post-deploy Volumes tab — offer THREE
  choices over these two types: managed, shared and folder. A managed and a shared
  volume are both `type: "volume"` and differ only in whether `source` is set, which is
  a distinction no single control can post. `kind/1` and `apply_kind/1` are that
  translation, and `normalize/1` applies it, so a row may state its `kind` or its
  `type`/`source` and mean the same thing.

  ## Inference

  `type` is inferred ONLY when absent, and only from the shape of `source`: an absolute
  path is a bind, anything else is a volume name. This is exactly the rule
  `SpecBuilder.build_volumes/3` applies when it builds the mount, so inference here can
  never disagree with what actually gets mounted.
  """

  import Ecto.Changeset

  alias Homelab.IndexedParams

  @doc """
  Normalizes indexed form params (`%{"0" => %{...}}`) or a plain list into an ordered
  list of canonical, string-keyed volume maps. Rows with no mount path are dropped —
  a blank row is an operator who added one and changed their mind, not an error.
  """
  def parse(volumes) do
    volumes
    |> parse_rows()
    |> Enum.reject(&blank?(&1["container_path"]))
  end

  @doc """
  Like `parse/1`, but KEEPS rows with no mount path — for a live-editing form, where a
  just-added blank row has to survive the next change event instead of vanishing under
  the operator's cursor.
  """
  def parse_rows(volumes), do: volumes |> ordered_rows() |> Enum.map(&normalize/1)

  @doc """
  Like `parse_rows/1`, but each row also carries the `"kind"` it is edited as — see
  `kind/1`. For an editor's working state only: the key is derived, and `normalize/1`
  does not put it on a row bound for storage.
  """
  def parse_editor_rows(volumes) do
    volumes
    |> ordered_rows()
    |> Enum.map(&Map.put(normalize(&1), "kind", kind(&1)))
  end

  defp ordered_rows(nil), do: []

  defp ordered_rows(volumes) when is_map(volumes), do: IndexedParams.ordered(volumes)

  defp ordered_rows(volumes) when is_list(volumes), do: volumes

  @doc """
  The kind of row an editor shows this volume as: `"managed"`, `"shared"` or `"bind"`.

  Three choices over two mount types, because the two named-volume rows differ only in
  whether `source` is set, and an editor cannot offer that as a checkbox without asking
  the operator to reason about a field being ABSENT. A row that names a volume is shown
  as shared even when this deployment owns it — the name is pinned to the row either
  way, and `borrowed` is what records who owns the data.

  A row that already carries a `"kind"` — one posted by an editor — is taken at its
  word. That matters for the one state the stored shape cannot express: a row just
  switched to shared, whose volume has not been picked yet, is indistinguishable from a
  managed row until it is.
  """
  def kind(%{"kind" => kind}) when kind in ["managed", "shared", "bind"], do: kind

  def kind(vol) when is_map(vol) do
    source = trim(vol["source"])

    cond do
      infer_type(vol["type"], source) == "bind" -> "bind"
      is_nil(source) -> "managed"
      true -> "shared"
    end
  end

  @doc """
  Resolves an editor's `"kind"` into the `type`/`source` pair it stands for.

  Managed clears the source, which is the whole of what makes a volume managed:
  `SpecBuilder` derives the name from the mount path when the row carries none. A row
  with no `"kind"` is left exactly as it came — every producer other than the two
  editors states its `type` directly.
  """
  def apply_kind(%{"kind" => "managed"} = vol),
    do: Map.merge(vol, %{"type" => "volume", "source" => ""})

  def apply_kind(%{"kind" => "shared"} = vol), do: Map.put(vol, "type", "volume")
  def apply_kind(%{"kind" => "bind"} = vol), do: Map.put(vol, "type", "bind")
  def apply_kind(vol), do: vol

  @doc """
  Canonicalizes a single volume map. Accepts the legacy `"path"` and `"target"` keys
  for the mount path, and form booleans as the strings `"true"`/`"false"`.
  """
  def normalize(vol) when is_map(vol) do
    vol = apply_kind(vol)
    source = trim(vol["source"])
    container_path = trim(vol["container_path"] || vol["path"] || vol["target"])

    %{
      "container_path" => container_path,
      "type" => infer_type(vol["type"], source),
      "source" => source,
      "description" => vol["description"] || "",
      "optional" => vol["optional"] in [true, "true"],
      # Whether the container may WRITE through this mount.
      #
      # There was no key for this at all, so a mount the operator deliberately made
      # read-only — a media library, a certificate bundle, a config directory shared
      # with another stack, `docker.sock` — was silently widened to read-write on
      # adoption and on compose import. Both parsers CAPTURED the flag (`RW` from the
      # daemon, the `:ro` suffix from compose) and dropped it one function later,
      # because there was nowhere to put it.
      #
      # Defaults to false (writable), which is Docker's own default and what every
      # existing stored volume means.
      "read_only" => vol["read_only"] in [true, "true"],
      # Whether the data behind this mount belongs to some other deployment.
      #
      # `type` is Docker's mount type and is passed to the daemon verbatim, so it cannot
      # carry this: to Docker there is one kind of named volume, and a library shared by
      # four apps is mounted exactly like a database's own data directory. Ownership is
      # ours to know, and nothing recorded it -- a deliberately shared media tree, a
      # volume adoption named, and a typo that minted an empty volume were the same row.
      #
      # Only a named volume can be borrowed. A bind mounts a host directory that this
      # deployment never owned in the first place, and a blank source is a volume derived
      # for THIS deployment, so both normalize to false rather than being refused: the
      # combination is meaningless, not dangerous.
      "borrowed" =>
        infer_type(vol["type"], source) == "volume" and source not in [nil, ""] and
          vol["borrowed"] in [true, "true"]
    }
  end

  @doc """
  Decides which rows are BORROWED, given what the deployment mounted before and the
  volumes the daemon already has.

  The decision is made once, when a mount is created or re-pointed, and carried from then
  on. Re-deciding on every save would be wrong in the one direction that matters: a
  volume this deployment created exists on the daemon by the next save, so an owned
  volume would quietly become a borrowed one, and the ownership picture would converge on
  "nobody owns anything".

  Rows are matched to their previous selves by mount path, the same key the rest of the
  wizard reconciles a service's rows on, and the one two volumes may not share.
  """
  def mark_borrowed(rows, previous, existing_names) do
    previous = Map.new(List.wrap(previous), &{normalize(&1)["container_path"], normalize(&1)})
    existing = MapSet.new(existing_names)

    Enum.map(rows, fn row ->
      row = normalize(row)
      before = previous[row["container_path"]]

      cond do
        row["type"] != "volume" or row["source"] in [nil, ""] ->
          Map.put(row, "borrowed", false)

        before && before["source"] == row["source"] ->
          Map.put(row, "borrowed", before["borrowed"])

        true ->
          Map.put(row, "borrowed", MapSet.member?(existing, row["source"]))
      end
    end)
  end

  defp infer_type(type, _source) when type in ["bind", "volume"], do: type
  defp infer_type(_type, "/" <> _rest), do: "bind"
  defp infer_type(_type, _source), do: "volume"

  @doc "True when this volume mounts a host folder rather than a Docker-managed volume."
  def bind?(vol), do: normalize(vol)["type"] == "bind"

  @doc """
  Validates a `{:array, :map}` volumes field on a changeset.

  Refuses, rather than repairs:

    * a relative mount path — a managed volume's NAME is derived from it, so a relative
      one yields a garbage name and mounts the wrong thing;

    * a bind with a non-absolute `source` — Docker reads a bare word as a NAMED VOLUME,
      not a path, so a typo'd bind source does not error. It quietly creates an empty
      volume and the app comes up with no data, which at a glance is indistinguishable
      from data loss;

    * two volumes at the same mount path — Docker takes one and drops the other, and
      which one it takes is not a coin worth flipping when the answer decides where an
      app's data lives.
  """
  def validate_changeset(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      volumes when is_list(volumes) ->
        volumes
        |> Enum.reduce(changeset, &validate_volume(&1, &2, field))
        |> validate_unique_paths(volumes, field)

      _ ->
        add_error(changeset, field, "must be a list")
    end
  end

  defp validate_volume(vol, changeset, field) do
    vol = normalize(vol)

    cond do
      not absolute?(vol["container_path"]) ->
        add_error(
          changeset,
          field,
          "mount path must be absolute (got #{inspect(vol["container_path"])})"
        )

      vol["type"] == "bind" and not absolute?(vol["source"]) ->
        add_error(
          changeset,
          field,
          "a folder mount needs an absolute host path (got #{inspect(vol["source"])}) — " <>
            "Docker reads a bare name as a named volume, so a typo would silently mount an empty one"
        )

      true ->
        changeset
    end
  end

  defp validate_unique_paths(changeset, volumes, field) do
    paths = Enum.map(volumes, &normalize(&1)["container_path"])

    if length(Enum.uniq(paths)) == length(paths),
      do: changeset,
      else: add_error(changeset, field, "two volumes cannot mount at the same path")
  end

  defp absolute?(path) when is_binary(path),
    do: String.starts_with?(path, "/") and String.trim(path) != "/"

  defp absolute?(_path), do: false

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp trim(nil), do: nil

  defp trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim(value), do: value
end
