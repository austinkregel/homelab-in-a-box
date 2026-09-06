defmodule HomelabWeb.SecretReveal do
  @moduledoc """
  The set of secret values an operator has asked to see, and the two ways it changes.

  Reveal has to be server state. Every screen that edits environment variables does it
  inside a `phx-change` form, so each keystroke re-renders the row; a `type` attribute
  flipped in the browser would be patched straight back to `password` on the next one.
  So each LiveView keeps a `MapSet` of the identifiers it has revealed, and
  `HomelabWeb.CoreComponents.secret_input/1` reads it.

  Identifiers are whatever addresses a row on that screen — a list index in the wizard
  and on a deployment, a variable name in the catalog. Both arrive from the client as
  strings, hence `toggle/2` normalising against what the set already holds.
  """

  @doc """
  Adds `id` to `revealed`, or removes it if it is already there.

  `id` is the raw `phx-value-secret` string. A wholly numeric one becomes an integer so
  it matches the indices an index-keyed screen stores; anything else stays a string. A
  variable name cannot be all digits, so the two never collide.
  """
  @spec toggle(MapSet.t(), String.t() | integer()) :: MapSet.t()
  def toggle(revealed, id) do
    id = normalize(id)

    if MapSet.member?(revealed, id) do
      MapSet.delete(revealed, id)
    else
      MapSet.put(revealed, id)
    end
  end

  @doc """
  Renumbers an index-keyed set after the row at `index` is deleted.

  Positions below the hole all shift up by one. Without this the set keeps pointing at
  the slots it was built against and unmasks whichever credential slid into them — a
  leak introduced by the very feature meant to make secrets legible on purpose.
  """
  @spec drop_index(MapSet.t(), integer()) :: MapSet.t()
  def drop_index(revealed, index) do
    revealed
    |> Enum.reject(&(&1 == index))
    |> Enum.map(fn i -> if i > index, do: i - 1, else: i end)
    |> MapSet.new()
  end

  # A row index reaches us as "3"; a variable name as "SMTP_PASS". Only the former is
  # meant to become an integer.
  defp normalize(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp normalize(id), do: id
end
