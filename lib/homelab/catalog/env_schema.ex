defmodule Homelab.Catalog.EnvSchema do
  @moduledoc """
  Per-variable description of a template's environment, alongside the flat
  `required_env` list.

  A flat list can only say "always required", which is wrong for an app with modes:
  gluetun needs WireGuard keys or OpenVPN credentials depending on `VPN_TYPE`, never
  both. A schema entry names the condition instead, and carries the metadata a form
  needs to collect the value.

      %{
        "VPN_TYPE" => %{"enum" => ["wireguard", "openvpn"], "required" => true},
        "WIREGUARD_PRIVATE_KEY" => %{
          "secret" => true,
          "required_when" => %{"VPN_TYPE" => "wireguard"}
        },
        "OPENVPN_USER" => %{"required_when" => %{"VPN_TYPE" => "openvpn"}}
      }

  Descriptor settings, all optional:

    * `"required"` — always required.
    * `"required_when"` — a map of other variables to the value(s) that switch this one
      on. Every entry must match; a value may be a string or a list of accepted strings.
    * `"enum"` — the values this variable accepts, for rendering a select.
    * `"secret"` — this variable holds a credential. Declared here but not yet wired to
      the masking or storage paths, which still guess from the name
      (`Homelab.SecretKeys.sensitive?/1`).
    * `"label"`, `"description"` — what to call it, and what it does.

  An empty schema is inert: `required_keys/2` returns `[]` and `required_env` is the
  whole answer.
  """

  import Ecto.Changeset

  @descriptor_keys ~w(required required_when enum secret label description)

  @doc "Normalizes a raw schema into the shape above, dropping anything unrecognized."
  @spec parse(term()) :: map()
  def parse(schema) when is_map(schema) do
    schema
    |> Enum.flat_map(fn
      {key, descriptor} when is_binary(key) and is_map(descriptor) ->
        [{key, parse_descriptor(descriptor)}]

      _other ->
        []
    end)
    |> Map.new()
  end

  def parse(_schema), do: %{}

  defp parse_descriptor(descriptor) do
    descriptor
    |> Enum.flat_map(fn {key, value} -> normalize_entry(to_string(key), value) end)
    |> Map.new()
  end

  defp normalize_entry("required", value), do: [{"required", value == true}]
  defp normalize_entry("secret", value), do: [{"secret", value == true}]

  defp normalize_entry("enum", values) when is_list(values) do
    case Enum.filter(values, &is_binary/1) do
      [] -> []
      allowed -> [{"enum", Enum.uniq(allowed)}]
    end
  end

  # Dropped whole rather than kept empty: an empty condition map satisfies `Enum.all?/2`,
  # which would make the variable unconditionally required.
  defp normalize_entry("required_when", conditions) when is_map(conditions) do
    case normalize_conditions(conditions) do
      empty when map_size(empty) == 0 -> []
      normalized -> [{"required_when", normalized}]
    end
  end

  defp normalize_entry(key, value) when key in ~w(label description) and is_binary(value),
    do: [{key, value}]

  defp normalize_entry(_key, _value), do: []

  defp normalize_conditions(conditions) do
    conditions
    |> Enum.flat_map(fn
      {key, values} when is_binary(key) ->
        case values |> List.wrap() |> Enum.filter(&is_binary/1) do
          [] -> []
          accepted -> [{key, Enum.uniq(accepted)}]
        end

      _other ->
        []
    end)
    |> Map.new()
  end

  @doc """
  The variables this schema demands, given the effective environment (template defaults
  with deployment overrides merged over them) that conditions are read against.
  """
  @spec required_keys(term(), map()) :: [String.t()]
  def required_keys(schema, env) when is_map(env) do
    schema
    |> parse()
    |> Enum.filter(fn {_key, descriptor} -> required?(descriptor, env) end)
    |> Enum.map(fn {key, _descriptor} -> key end)
    |> Enum.sort()
  end

  defp required?(%{"required" => true}, _env), do: true

  defp required?(%{"required_when" => conditions}, env) do
    Enum.all?(conditions, fn {key, accepted} ->
      to_string(Map.get(env, key, "")) in accepted
    end)
  end

  defp required?(_descriptor, _env), do: false

  @doc "The values a variable accepts, or `[]` when it is free text."
  @spec enum(term(), String.t()) :: [String.t()]
  def enum(schema, key), do: schema |> parse() |> get_in([key, "enum"]) || []

  @doc "True when a variable is declared to hold a credential."
  @spec secret?(term(), String.t()) :: boolean()
  def secret?(schema, key), do: schema |> parse() |> get_in([key, "secret"]) == true

  @doc """
  Rejects a schema whose shape means something other than what its author wrote.

  Every rule guards a mistake `parse/1` would otherwise absorb into "not required".
  """
  @spec validate_changeset(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_changeset(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      schema when is_map(schema) ->
        case schema_errors(schema) do
          [] -> changeset
          errors -> add_error(changeset, field, Enum.join(errors, "; "))
        end

      _other ->
        add_error(changeset, field, "must be a map of variable name to description")
    end
  end

  defp schema_errors(schema) do
    Enum.flat_map(schema, fn {key, descriptor} -> descriptor_errors(schema, key, descriptor) end)
  end

  defp descriptor_errors(_schema, key, descriptor)
       when not is_binary(key) or not is_map(descriptor),
       do: ["#{inspect(key)} must name a variable and describe it with a map"]

  defp descriptor_errors(schema, key, descriptor) do
    unknown_keys(key, descriptor) ++
      enum_errors(key, descriptor) ++
      condition_errors(schema, key, descriptor)
  end

  # `parse/1` drops what it does not recognize, so a misspelled setting would leave the
  # variable optional with nothing to say why.
  defp unknown_keys(key, descriptor) do
    descriptor
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 in @descriptor_keys))
    |> case do
      [] -> []
      unknown -> ["#{key} has unrecognized settings: #{Enum.join(unknown, ", ")}"]
    end
  end

  defp enum_errors(key, descriptor) do
    case Map.get(descriptor, "enum") do
      nil -> []
      values when is_list(values) -> non_empty_strings(key, "enum", values)
      _other -> ["#{key}'s enum must be a list of allowed values"]
    end
  end

  defp non_empty_strings(key, setting, values) do
    if values != [] and Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      []
    else
      ["#{key}'s #{setting} must be a non-empty list of strings"]
    end
  end

  defp condition_errors(schema, key, descriptor) do
    case Map.get(descriptor, "required_when") do
      nil ->
        []

      conditions when is_map(conditions) and map_size(conditions) > 0 ->
        undescribed_condition_keys(schema, key, conditions) ++
          Enum.flat_map(conditions, fn {on, values} ->
            non_empty_strings(key, "condition on #{on}", List.wrap(values))
          end)

      _other ->
        ["#{key}'s required_when must be a non-empty map of variable to accepted value"]
    end
  end

  # A mistyped condition key is never met, so its variable is never required. Conditions
  # may only name variables the same schema describes.
  defp undescribed_condition_keys(schema, key, conditions) do
    conditions
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(schema, &1))
    |> case do
      [] -> []
      unknown -> ["#{key} is conditional on undescribed variables: #{Enum.join(unknown, ", ")}"]
    end
  end
end
