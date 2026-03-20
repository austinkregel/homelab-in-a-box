defmodule HomelabWeb.Router do
  use HomelabWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HomelabWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug HomelabWeb.Plugs.RequireSetup
  end

  pipeline :authenticated do
    plug HomelabWeb.Plugs.RequireAuth
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Auth controller routes (not LiveView, no on_mount needed)
  scope "/auth", HomelabWeb do
    pipe_through :browser

    get "/oidc", AuthController, :login
    get "/oidc/callback", AuthController, :callback
    get "/logout", AuthController, :logout
  end

  # Setup wizard -- blocked once setup is complete
  scope "/", HomelabWeb do
    pipe_through :browser

    live_session :setup, on_mount: [{HomelabWeb.Live.Hooks, :redirect_if_setup_done}] do
      live "/setup", SetupLive, :index
    end
  end

  # Authenticated routes -- blocked until setup is complete AND user is authenticated
  scope "/", HomelabWeb do
    pipe_through [:browser, :authenticated]

    live_session :authenticated,
      on_mount: [
        {HomelabWeb.Live.Hooks, :require_setup},
        {HomelabWeb.Live.Hooks, :require_auth}
      ] do
      live "/", DashboardLive, :index
      live "/catalog", CatalogLive, :index
      live "/deploy/new", DeployWizardLive, :new
      live "/tenants/:id", TenantLive, :show
      live "/deployments/:id", DeploymentLive, :show
      live "/domains", DomainsLive, :index
      live "/backups", BackupsLive, :index
      live "/activity", ActivityLive, :index
      live "/settings", SettingsLive, :index
    end
  end

  scope "/api/v1", HomelabWeb.Api.V1 do
    pipe_through :api

    resources "/tenants", TenantController, except: [:new, :edit] do
      resources "/deployments", DeploymentController, except: [:new, :edit]
    end

    resources "/app-templates", AppTemplateController, only: [:index, :show]
    resources "/backups", BackupController, only: [:index, :show, :create]
    post "/backups/:id/restore", BackupController, :restore

    get "/health", HealthController, :index
  end

  if Application.compile_env(:homelab, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: HomelabWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
