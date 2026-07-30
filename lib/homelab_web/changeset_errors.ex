defmodule HomelabWeb.ChangesetErrors do
  @moduledoc """
  Turns a changeset's errors into something an operator can act on.

  Every validation in this app was written to explain itself. `Netns` alone refuses ten
  distinct ways — wrong space, a chain, a port already taken inside the donor's namespace
  (naming the sibling that holds it), host mode, Swarm — and each message says what is
  wrong and what to do instead.

  The LiveViews then threw all of it away. `DeploymentLive.apply_config/3` answered any
  `%Ecto.Changeset{}` with "Could not save the configuration.", so all ten produced the
  same six words, and the wizard rendered `inspect(changeset.errors)` — a keyword list
  with `%{count}` placeholders still in it. A refusal nobody can read is
  indistinguishable from a broken feature, which is exactly how it was reported.

  `to_sentence/1` is the operator-facing message; `to_map/1` is the same traversal shaped
  for JSON.
  """

  @doc "Field-keyed, interpolated messages — the shape the JSON API returns."
  @spec to_map(Ecto.Changeset.t()) :: map()
  def to_map(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, &interpolate/1)
  end

  @doc """
  One readable sentence covering every error on the changeset.

  Two message styles coexist here and both have to read correctly. Ecto's own validations
  return sentence *fragments* ("can't be blank"), which need the field name in front of
  them. Several of ours return whole sentences that already name their own subject
  ("Docker Swarm cannot share a network namespace between services — ..."), and prefixing
  those yields "network parent id Docker Swarm cannot...".

  So the leading character decides: an upper-case message stands alone, a lower-case one
  gets its humanized field. That is a convention rather than a guarantee, which is why it
  degrades into a slightly clumsy sentence rather than a wrong one.
  """
  @spec to_sentence(Ecto.Changeset.t()) :: String.t()
  def to_sentence(%Ecto.Changeset{} = changeset) do
    changeset
    |> to_map()
    |> Enum.flat_map(fn {field, messages} ->
      messages
      |> List.wrap()
      |> Enum.map(&phrase(field, &1))
    end)
    |> case do
      [] -> "Could not save the configuration."
      phrases -> Enum.join(phrases, "; ")
    end
  end

  # Nested changesets (`cast_assoc`) traverse to a map rather than a list of strings.
  # Flattened with the child's field names kept, since "extra_routes port is invalid" is
  # the only version that says which row.
  defp phrase(field, %{} = nested) do
    nested
    |> Enum.flat_map(fn {child, messages} ->
      messages |> List.wrap() |> Enum.map(&phrase("#{field} #{child}", &1))
    end)
    |> Enum.join("; ")
  end

  defp phrase(field, message) when is_binary(message) do
    if standalone?(message), do: message, else: "#{humanize(field)} #{message}"
  end

  defp standalone?(<<first::utf8, _rest::binary>>), do: first == :string.to_upper(first)
  defp standalone?(_message), do: false

  # `network_parent_id` reads as "Network parent", not "Network parent id". The `_id` and
  # `_override` suffixes are how this schema spells a foreign key and an inherited-value
  # column; neither is something an operator typed or should have to know.
  defp humanize(field) do
    field
    |> to_string()
    |> String.replace_suffix("_override", "")
    |> String.replace_suffix("_id", "")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp interpolate({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
      opts
      |> Keyword.get(String.to_existing_atom(key), key)
      |> to_string()
    end)
  end
end
