defmodule Homelab.Deployments.Datastore.Databases do
  @moduledoc """
  Turns a datastore's env into the set of databases that must exist.

  ## The declaration

  `HOMELAB_DATABASES` — a comma-, space- or newline-separated list:

      HOMELAB_DATABASES=sonarr-main,sonarr-log,radarr-main,radarr-log

  The engine's own single-database env (`POSTGRES_DB`, `MARIADB_DATABASE`,
  `MYSQL_DATABASE`) is folded in as well. Those variables already MEAN "this database
  should exist" to every operator who has read the image's README — they just happen
  to mean it only on first init. Honouring them here makes them mean it always, so the
  obvious thing an operator types is the thing that works, and a second database is
  one more entry rather than a different mechanism.

  Order is preserved and duplicates collapse, so the declaration reads back the way it
  was written and re-listing a name is harmless.

  ## What it deliberately does not do

  No drops. A name removed from the declaration is left alone, because the alternative
  is a typo in an env var destroying a database. Removing data stays a deliberate,
  separate act.
  """

  alias Homelab.Deployments.Datastore.Engine

  @declaration "HOMELAB_DATABASES"

  # The engine-native spellings, all of which are first-init-only to the images
  # themselves. Folded into the declaration so they keep working after first init.
  @native_keys ~w(POSTGRES_DB MARIADB_DATABASE MYSQL_DATABASE)

  @doc "The env var operators write the list in."
  def declaration_key, do: @declaration

  @doc """
  The database names declared by `env`, in declaration order, de-duplicated.

  Returns `{:error, {:invalid_database_name, name}}` for anything outside the
  identifier allow-list, so a shell-injecting name fails the release instead of
  reaching the server.
  """
  @spec declared(map()) :: {:ok, [String.t()]} | {:error, term()}
  def declared(env) when is_map(env) do
    names =
      [env[@declaration] | Enum.map(@native_keys, &env[&1])]
      |> Enum.flat_map(&split/1)
      |> Enum.uniq()

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case Engine.validate_identifier(name) do
        {:ok, valid} -> {:cont, {:ok, [valid | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  def declared(_env), do: {:ok, []}

  @doc """
  The SQL that makes every declared database exist, or `nil` when nothing is
  declared — the caller skips rather than starting a container to run no statements.
  """
  @spec build_sql(Engine.t(), [String.t()]) :: String.t() | nil
  def build_sql(_engine, []), do: nil

  def build_sql(engine, databases) do
    databases
    |> Enum.map_join("\n", &engine.ensure_database_sql/1)
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp split(nil), do: []

  defp split(value) when is_binary(value) do
    value
    |> String.split([",", " ", "\n", "\t", "\r"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split(_value), do: []
end
