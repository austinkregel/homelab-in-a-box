defmodule Homelab.Storage do
  @moduledoc """
  Storage facade. ZFS-backed features are optional: when the host
  `homelab-zfs-agent` socket is absent, `available?/0` is false and
  pool/dataset/snapshot operations are not offered in the UI.
  """

  alias Homelab.Storage.Zfs.HostAgent

  @doc "True when the host ZFS agent socket exists and responds to hello."
  @spec available?() :: boolean()
  def available? do
    socket = HostAgent.socket_path()

    if File.exists?(socket) do
      case agent_status() do
        {:ok, _} -> true
        _ -> false
      end
    else
      false
    end
  end

  @doc """
  Returns `{:ok, %{protocol_version: n}}` or an error such as
  `:agent_unavailable`, `:protocol_mismatch`, or `{:connect_failed, _}`.
  """
  @spec agent_status() :: {:ok, map()} | {:error, term()}
  def agent_status do
    case Homelab.Storage.Zfs.impl().protocol_version() do
      {:ok, v} -> {:ok, %{protocol_version: v, socket: HostAgent.socket_path()}}
      {:error, :agent_unavailable} -> {:error, :agent_unavailable}
      other -> other
    end
  end

  @doc "Human-readable reason storage is unavailable (for UI banners)."
  @spec unavailable_reason() :: String.t() | nil
  def unavailable_reason do
    cond do
      available?() ->
        nil

      not File.exists?(HostAgent.socket_path()) ->
        unavailable_reason_from_status({:error, :agent_unavailable})

      true ->
        unavailable_reason_from_status(agent_status())
    end
  end

  defp unavailable_reason_from_status({:error, :agent_unavailable}) do
    "ZFS host agent is not running (#{HostAgent.socket_path()}). " <>
      "Install ZFS and homelab-zfs-agent when ready; the control plane works without it."
  end

  defp unavailable_reason_from_status({:error, {:protocol_mismatch, expected: e, got: g}}) do
    "ZFS agent protocol mismatch (expected #{e}, got #{g})."
  end

  defp unavailable_reason_from_status({:error, reason}) do
    "Storage unavailable: #{inspect(reason)}"
  end

  defp unavailable_reason_from_status(_), do: "Storage unavailable."
end
