defmodule Homelab.Settings do
  @moduledoc """
  DB-backed system settings with an ETS cache layer.

  Secrets (OIDC client secret, registry tokens) are stored encrypted
  at rest. The ETS cache is invalidated via PubSub so all nodes
  see updates immediately.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Settings.SystemSetting

  @cache_table :homelab_settings_cache
  @pubsub_topic "settings:invalidate"

  # --- Cache lifecycle ---

  def init_cache do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end

    :ok
  end

  def warm_cache do
    init_cache()

    list_all()
    |> Enum.each(fn setting ->
      :ets.insert(@cache_table, {setting.key, decode_value(setting)})
    end)
  end

  # --- Public API ---

  def get(key, default \\ nil) do
    init_cache()

    case :ets.lookup(@cache_table, key) do
      [{^key, value}] -> value
      [] -> fetch_and_cache(key, default)
    end
  end

  def get!(key) do
    case get(key) do
      nil -> raise "Setting #{key} not found"
      value -> value
    end
  end

  def set(key, value, opts \\ []) do
    category = Keyword.get(opts, :category, "general")
    encrypt? = Keyword.get(opts, :encrypt, false)

    stored_value = if encrypt?, do: encrypt(to_string(value)), else: to_string(value)

    attrs = %{key: key, value: stored_value, encrypted: encrypt?, category: category}

    result =
      case Repo.get_by(SystemSetting, key: key) do
        nil ->
          %SystemSetting{}
          |> SystemSetting.changeset(attrs)
          |> Repo.insert()

        existing ->
          existing
          |> SystemSetting.changeset(attrs)
          |> Repo.update()
      end

    case result do
      {:ok, setting} ->
        init_cache()
        :ets.insert(@cache_table, {key, decode_value(setting)})
        broadcast_invalidation(key)
        {:ok, setting}

      error ->
        error
    end
  end

  def delete(key) do
    case Repo.get_by(SystemSetting, key: key) do
      nil ->
        :ok

      setting ->
        Repo.delete(setting)
        init_cache()
        :ets.delete(@cache_table, key)
        broadcast_invalidation(key)
        :ok
    end
  end

  def all_by_category(category) do
    SystemSetting
    |> where([s], s.category == ^category)
    |> Repo.all()
    |> Enum.map(fn s -> {s.key, decode_value(s)} end)
    |> Map.new()
  end

  def setup_completed? do
    get("setup_completed") == "true"
  end

  def mark_setup_completed do
    set("setup_completed", "true", category: "system")
  end

  # --- PubSub ---

  def subscribe do
    Phoenix.PubSub.subscribe(Homelab.PubSub, @pubsub_topic)
  end

  defp broadcast_invalidation(key) do
    Phoenix.PubSub.broadcast(Homelab.PubSub, @pubsub_topic, {:setting_changed, key})
  end

  # --- Private ---

  defp list_all do
    Repo.all(SystemSetting)
  end

  defp fetch_and_cache(key, default) do
    case Repo.get_by(SystemSetting, key: key) do
      nil ->
        default

      setting ->
        value = decode_value(setting)
        :ets.insert(@cache_table, {key, value})
        value
    end
  end

  defp decode_value(%SystemSetting{encrypted: true, value: value}) when is_binary(value) do
    decrypt(value)
  end

  defp decode_value(%SystemSetting{value: value}), do: value

  defp encrypt(plaintext) do
    secret = encryption_key()
    iv = :crypto.strong_rand_bytes(16)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, plaintext, "", true)

    Base.encode64(iv <> tag <> ciphertext)
  end

  defp decrypt(encoded) do
    secret = encryption_key()
    decoded = Base.decode64!(encoded)
    <<iv::binary-16, tag::binary-16, ciphertext::binary>> = decoded
    :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, ciphertext, "", tag, false)
  end

  defp encryption_key do
    base =
      Application.get_env(:homelab, HomelabWeb.Endpoint)[:secret_key_base] ||
        "default-dev-key-that-should-be-replaced-in-production!!"

    :crypto.hash(:sha256, base)
  end
end
