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

  Every producer of a volume map (the deploy wizard, the compose parser, the adoption
  planner, the post-deploy Volumes tab) normalizes through here, and both schemas that
  persist one (`AppTemplate.volumes`, `Deployment.volumes_override`) validate through
  here. Before this module each producer invented its own shape, and the ones that
  forgot `type`/`source` silently downgraded a folder mount to an empty named volume.

  ## Inference

  `type` is inferred ONLY when absent, and only from the shape of `source`: an absolute
  path is a bind, anything else is a volume name. This is exactly the rule
  `SpecBuilder.build_volumes/3` applies when it builds the mount, so inference here can
  never disagree with what actually gets mounted.
  """

  import Ecto.Changeset

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
  def parse_rows(nil), do: []

  def parse_rows(volumes) when is_map(volumes) do
    volumes
    |> Enum.sort_by(fn {idx, _row} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, row} -> normalize(row) end)
  end

  def parse_rows(volumes) when is_list(volumes) do
    Enum.map(volumes, &normalize/1)
  end

  @doc """
  Canonicalizes a single volume map. Accepts the legacy `"path"` and `"target"` keys
  for the mount path, and form booleans as the strings `"true"`/`"false"`.
  """
  def normalize(vol) when is_map(vol) do
    source = trim(vol["source"])
    container_path = trim(vol["container_path"] || vol["path"] || vol["target"])

    %{
      "container_path" => container_path,
      "type" => infer_type(vol["type"], source),
      "source" => source,
      "description" => vol["description"] || "",
      "optional" => vol["optional"] in [true, "true"]
    }
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
