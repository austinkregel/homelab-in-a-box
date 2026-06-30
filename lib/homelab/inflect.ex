defmodule Homelab.Inflect do
  @moduledoc """
  Minimal English verb conjugation for UI button labels.

  Given a verb-led label like `"Save"`, `"Deploy"`, or `"Sync Registrar"`,
  produces the gerund ("Saving", "Deploying", "Syncing Registrar") and the
  past tense ("Saved", "Deployed", "Synced Registrar").

  This deliberately covers only the short action verbs used on the app's
  buttons via standard rules plus a small irregular map — it is not a general
  NLP inflector. When only the leading word is a verb and the rest is a noun
  phrase (e.g. "Sync Registrar"), only the leading verb is conjugated and the
  remainder is preserved verbatim.
  """

  # Irregular verbs that appear (or might appear) on action buttons.
  # Keyed by lowercase root → {gerund, past}.
  @irregular %{
    "send" => {"sending", "sent"},
    "build" => {"building", "built"},
    "rebuild" => {"rebuilding", "rebuilt"},
    "run" => {"running", "ran"},
    "rerun" => {"rerunning", "reran"},
    "undo" => {"undoing", "undid"},
    "redo" => {"redoing", "redid"},
    "set" => {"setting", "set"},
    "reset" => {"resetting", "reset"},
    "begin" => {"beginning", "began"},
    "rebuilt" => {"rebuilding", "rebuilt"}
  }

  @vowels ~c"aeiou"

  # Multi-syllable verbs stressed on the final syllable, which double their
  # final consonant (submit → submitting). Single-syllable CVC words double
  # automatically; multi-syllable ones (edit → editing) do not unless listed.
  @final_stress ~w(submit commit permit omit refer prefer occur control)

  @doc """
  Returns the present-participle (gerund) form of a verb-led `label`.

  ## Examples

      iex> Homelab.Inflect.gerund("Save")
      "Saving"

      iex> Homelab.Inflect.gerund("Sync Registrar")
      "Syncing Registrar"
  """
  def gerund(label), do: conjugate(label, :gerund)

  @doc """
  Returns the simple-past form of a verb-led `label`.

  ## Examples

      iex> Homelab.Inflect.past("Save")
      "Saved"

      iex> Homelab.Inflect.past("Deploy")
      "Deployed"
  """
  def past(label), do: conjugate(label, :past)

  defp conjugate(label, form) when is_binary(label) do
    case String.split(label, " ", parts: 2) do
      [verb] -> verb |> inflect(form) |> match_case(verb)
      [verb, rest] -> (inflect(verb, form) |> match_case(verb)) <> " " <> rest
    end
  end

  defp inflect(verb, form) do
    root = String.downcase(verb)

    case @irregular[root] do
      {gerund, _past} when form == :gerund -> gerund
      {_gerund, past} when form == :past -> past
      nil -> regular(root, form)
    end
  end

  defp regular(root, :gerund) do
    cond do
      String.ends_with?(root, "ie") -> String.slice(root, 0..-3//1) <> "ying"
      drop_silent_e?(root) -> String.slice(root, 0..-2//1) <> "ing"
      double_final?(root) -> root <> String.last(root) <> "ing"
      true -> root <> "ing"
    end
  end

  defp regular(root, :past) do
    cond do
      String.ends_with?(root, "e") -> root <> "d"
      consonant_y?(root) -> String.slice(root, 0..-2//1) <> "ied"
      double_final?(root) -> root <> String.last(root) <> "ed"
      true -> root <> "ed"
    end
  end

  # Silent trailing "e" that is dropped before "ing" (save → saving),
  # but not "ee"/"oe"/"ye" (see → seeing, dye → dyeing).
  defp drop_silent_e?(root) do
    String.ends_with?(root, "e") and
      not String.ends_with?(root, "ee") and
      not String.ends_with?(root, "oe") and
      not String.ends_with?(root, "ye")
  end

  # Consonant followed by "y" (apply → applied), as opposed to vowel + "y"
  # (deploy → deployed).
  defp consonant_y?(root) do
    case String.to_charlist(root) |> Enum.reverse() do
      [?y, prev | _] -> prev not in @vowels
      _ -> false
    end
  end

  # Consonant-vowel-consonant words double the final consonant (stop → stopping,
  # set → setting). Only single-syllable words double automatically; multi-syllable
  # words double only when stressed on the final syllable (submit → submitting,
  # but edit → editing). Excludes final w/x/y, which never double.
  defp double_final?(root) do
    cvc?(root) and (single_syllable?(root) or root in @final_stress)
  end

  defp cvc?(root) do
    case String.to_charlist(root) |> Enum.reverse() do
      [last, vowel, before | _] ->
        last in ~c"bcdfgklmnprt" and vowel in @vowels and before not in @vowels

      _ ->
        false
    end
  end

  # One maximal run of vowels means one syllable (rough but sufficient here).
  defp single_syllable?(root) do
    root
    |> String.to_charlist()
    |> Enum.chunk_by(&(&1 in @vowels))
    |> Enum.count(fn [h | _] -> h in @vowels end) == 1
  end

  # Re-apply the original word's leading capitalization to the conjugated form.
  defp match_case(conjugated, original) do
    case String.first(original) do
      nil ->
        conjugated

      first ->
        if first == String.upcase(first), do: capitalize_first(conjugated), else: conjugated
    end
  end

  defp capitalize_first(<<first::utf8, rest::binary>>),
    do: String.upcase(<<first::utf8>>) <> rest

  defp capitalize_first(s), do: s
end
