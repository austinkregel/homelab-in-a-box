defmodule Homelab.IndexedParams do
  @moduledoc """
  Reads the indexed row maps Phoenix posts for a repeating form section.

  A list of rows arrives as `%{"0" => row, "1" => row}` — a map, because HTML form
  names have no list type — so every editor that renders repeating rows has to sort by
  the numeric key to get the operator's order back.

  ## The marker that is not a row

  LiveView also posts a `_unused_<name>` marker beside every input the operator has not
  typed in yet, which is how `Phoenix.HTML.FormField.used_input?/1` knows not to show
  an error on a field nobody has touched. Those markers land in the SAME map:

      %{"_unused_0" => "", "0" => %{"key" => "…"}}

  So the obvious `Enum.sort_by(params, &String.to_integer(elem(&1, 0)))` raises
  `ArgumentError: not a textual representation of an integer` on `"_unused_0"`, and
  because this runs inside `handle_event`, the crash takes the LiveView process with
  it: the page resets and the operator's unsaved edits are gone. It presents as the
  form "not saving" rather than as an error, which is what makes it expensive to find.

  Eight parsers had their own copy of that sort. This is the one place that knows a
  numbered key is a row and everything else is a marker.
  """

  @doc """
  The rows of an indexed param map, in numeric key order, with markers discarded.

  Accepts the shapes a parser actually receives: the indexed map, an already-built
  list (some producers hand rows over directly), and `nil`.
  """
  @spec ordered(map() | list() | nil) :: list()
  def ordered(params) when is_map(params) do
    params
    |> Enum.flat_map(fn {key, row} ->
      case Integer.parse(key) do
        {position, ""} -> [{position, row}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn {position, _row} -> position end)
    |> Enum.map(fn {_position, row} -> row end)
  end

  def ordered(params) when is_list(params), do: params
  def ordered(_params), do: []

  @doc """
  Drops the `_unused_*` markers from a param map, keeping every real key.

  For the parsers that do not sort by index but still have to reason about the keys —
  telling an indexed row map (`%{"0" => %{…}}`) apart from a flat one
  (`%{"DB_HOST" => "…"}`) by whether the values are maps, say. A marker's value is the
  empty string, so it makes an indexed map look flat, and the parser silently emits a
  row named `_unused_0` instead of raising. Wrong output is harder to notice than a
  crash, which is why this is separate from `ordered/1` rather than folded into it.
  """
  @spec without_markers(map()) :: map()
  def without_markers(params) when is_map(params) do
    Map.reject(params, fn {key, _value} ->
      is_binary(key) and String.starts_with?(key, "_unused_")
    end)
  end

  def without_markers(params), do: params
end
