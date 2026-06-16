defmodule HomelabWeb.Components.StorageBanner do
  @moduledoc false
  use Phoenix.Component

  @doc "Shows when ZFS / host agent is not available."
  attr :reason, :string, default: nil

  def storage_unavailable(assigns) do
    assigns =
      assign_new(assigns, :reason, fn ->
        Homelab.Storage.unavailable_reason()
      end)

    ~H"""
    <div
      :if={@reason}
      id="global-storage-unavailable-banner"
      class="mb-4 rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-3 text-sm text-amber-100"
    >
      <p class="font-medium">Storage layer offline</p>
      <p class="mt-1 text-amber-200/80">{@reason}</p>
    </div>
    """
  end
end
