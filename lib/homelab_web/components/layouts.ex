defmodule HomelabWeb.Layouts do
  @moduledoc """
  Application layouts and sidebar navigation.
  """
  use HomelabWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :page_title, :string, default: nil, doc: "the current page title for nav highlighting"
  attr :tenants, :list, default: [], doc: "list of tenants to show in the sidebar"
  attr :current_user, :map, default: nil, doc: "the currently logged-in user"
  attr :notification_count, :integer, default: 0, doc: "unread notification count"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-base-200">
      <aside class="flex flex-col w-64 shrink-0 bg-base-300">
        <div class="px-4 py-4">
          <a href="/" class="flex items-center gap-3">
            <div class="w-8 h-8 rounded-lg bg-primary/90 flex items-center justify-center">
              <.icon name="hero-server-stack-solid" class="size-4 text-primary-content" />
            </div>
            <div>
              <span class="font-bold text-sm text-base-content tracking-tight">Homelab</span>
              <span class="block text-[11px] text-base-content/40 font-medium">
                Home-Lab-in-a-Box
              </span>
            </div>
          </a>
        </div>

        <nav class="flex-1 px-3 py-2 overflow-y-auto">
          <p class="px-3 mb-2 text-[10px] font-semibold uppercase tracking-widest text-base-content/25">
            Main
          </p>
          <div class="space-y-0.5">
            <.sidebar_link
              path={~p"/"}
              icon="hero-squares-2x2"
              label="Dashboard"
              active={@page_title == "Dashboard"}
            />
            <.sidebar_link
              path={~p"/catalog"}
              icon="hero-rectangle-stack"
              label="App Catalog"
              active={@page_title == "App Catalog"}
            />
            <.sidebar_link
              path={~p"/deploy/new"}
              icon="hero-rocket-launch"
              label="New Deployment"
              active={@page_title == "New Deployment"}
            />
            <.sidebar_link
              path={~p"/domains"}
              icon="hero-globe-alt"
              label="Domains"
              active={@page_title == "Domains"}
            />
            <.sidebar_link
              path={~p"/backups"}
              icon="hero-archive-box"
              label="Backups"
              active={@page_title == "Backups"}
            />
            <.sidebar_link
              path={~p"/activity"}
              icon="hero-clock"
              label="Activity"
              active={@page_title == "Activity"}
            />
          </div>

          <div class="mt-5">
            <p class="px-3 mb-2 text-[10px] font-semibold uppercase tracking-widest text-base-content/25">
              Spaces
            </p>
            <div :if={@tenants == []} class="px-3 py-2">
              <p class="text-xs text-base-content/30 italic">No spaces yet</p>
            </div>
            <div :if={@tenants != []} class="space-y-0.5">
              <.link
                :for={tenant <- @tenants}
                navigate={~p"/tenants/#{tenant.id}"}
                class="flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-content/5 transition-colors"
              >
                <.icon name="hero-folder-solid" class="size-4 opacity-50" />
                <span class="truncate">{tenant.name}</span>
              </.link>
            </div>
          </div>
        </nav>

        <div class="px-3 py-3 border-t border-base-content/5 space-y-1">
          <.sidebar_link
            path={~p"/settings"}
            icon="hero-cog-6-tooth"
            label="Settings"
            active={@page_title == "Settings"}
          />
          <div :if={@current_user} class="flex items-center gap-3 px-3 py-2">
            <div class="w-8 h-8 rounded-full bg-primary/20 flex items-center justify-center flex-shrink-0">
              <span class="text-xs font-bold text-primary">
                {String.first(@current_user.name || @current_user.email || "?")}
              </span>
            </div>
            <div class="min-w-0 flex-1">
              <p class="text-xs font-medium text-base-content truncate">
                {@current_user.name || @current_user.email}
              </p>
              <.link
                href={~p"/auth/logout"}
                class="text-[10px] text-base-content/40 hover:text-base-content/60 transition-colors"
              >
                Sign out
              </.link>
            </div>
            <div :if={@notification_count > 0} class="relative">
              <.icon name="hero-bell" class="size-5 text-base-content/50" />
              <span class="absolute -top-1 -right-1 w-4 h-4 rounded-full bg-error text-[10px] font-bold text-white flex items-center justify-center">
                {min(@notification_count, 9)}
              </span>
            </div>
          </div>
          <div class="flex items-center gap-2.5 px-3 py-1.5">
            <span class="w-2 h-2 rounded-full bg-success shadow-[0_0_6px_var(--color-success)]">
            </span>
            <span class="text-xs font-medium text-base-content/40">System ready</span>
          </div>
          <.theme_toggle />
        </div>
      </aside>

      <main class="flex-1 overflow-y-auto min-w-0">
        <div class="px-6 py-6 lg:px-8 lg:py-6 max-w-7xl mx-auto">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Minimal layout for the setup wizard -- no sidebar navigation.
  """
  attr :flash, :map, required: true
  attr :page_title, :string, default: nil

  slot :inner_block, required: true

  def setup(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200">
      <div class="fixed top-0 left-0 right-0 z-10 bg-base-300 border-b border-base-content/5">
        <div class="max-w-xl mx-auto px-6 py-3 flex items-center gap-3">
          <div class="w-8 h-8 rounded-lg bg-primary/90 flex items-center justify-center">
            <.icon name="hero-server-stack-solid" class="size-4 text-primary-content" />
          </div>
          <div>
            <span class="font-bold text-sm text-base-content tracking-tight">Homelab</span>
            <span class="block text-[11px] text-base-content/40 font-medium">
              Initial Setup
            </span>
          </div>
        </div>
      </div>

      <main class="pt-16 pb-8">
        <div class="max-w-7xl mx-auto px-6">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class={[
        "flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium transition-colors",
        if(@active,
          do: "bg-primary/15 text-primary",
          else: "text-base-content/60 hover:text-base-content hover:bg-base-content/5"
        )
      ]}
    >
      <.icon name={@icon} class={["size-5", if(@active, do: "text-primary", else: "opacity-60")]} />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center bg-base-content/5 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full bg-base-content/10 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex items-center justify-center p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-3.5 opacity-50 hover:opacity-100" />
      </button>

      <button
        class="flex items-center justify-center p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-3.5 opacity-50 hover:opacity-100" />
      </button>

      <button
        class="flex items-center justify-center p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-3.5 opacity-50 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
