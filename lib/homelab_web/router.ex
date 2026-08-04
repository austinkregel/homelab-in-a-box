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

  pipeline :admin do
    plug HomelabWeb.Plugs.RequireAdmin
  end

  pipeline :api do
    plug :accepts, ["json"]
    # The only API credential this app has is the browser session cookie, and
    # `Plug.Session` in the endpoint merely REGISTERS a lazy fetcher — it does not
    # fetch. Without this, `RequireAuthApi` raises "session not fetched" and every
    # authenticated request 500s.
    plug :fetch_session
  end

  pipeline :api_authenticated do
    plug HomelabWeb.Plugs.RequireAuthApi
  end

  # Auth controller routes (not LiveView, no on_mount needed)
  scope "/auth", HomelabWeb do
    pipe_through :browser

    get "/oidc", AuthController, :login
    get "/oidc/callback", AuthController, :callback
    get "/logout", AuthController, :logout

    # Emergency, non-OIDC admin login. 404s unless HOMELAB_BREAKGLASS_TOKEN is set
    # (see Homelab.Auth.BreakGlass). The way back in when the OIDC provider — which
    # may itself be hosted here — is down.
    get "/break-glass", BreakGlassController, :new
    post "/break-glass", BreakGlassController, :create
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
        {HomelabWeb.Live.Hooks, :require_auth},
        {HomelabWeb.Live.Hooks, :notifications}
      ] do
      live "/", DashboardLive, :index
      live "/catalog", CatalogLive, :index
      live "/workbench", WorkbenchLive, :index
      live "/deploy/new", DeployWizardLive, :new
      live "/tenants/:id", TenantLive, :show
      live "/deployments/:id", DeploymentLive, :show
      live "/domains", DomainsLive, :index
      live "/backups", BackupsLive, :index
      live "/activity", ActivityLive, :index
      live "/telemetry", TelemetryLive, :index
    end
  end

  # Administrator-only routes.
  #
  # Settings is the whole of it, deliberately. There is no user<->tenant relationship in
  # the schema, so "member" means "full access to everything" and gating a route is a
  # blunt instrument — gate too much and non-admins can no longer use the box at all.
  # Settings is different in kind from the rest: it is where privilege is GRANTED (the
  # role dropdown) and where authentication itself can be switched back OFF (`rerun_setup`
  # deletes `setup_completed`, and RequireAuth deliberately fails open while setup is
  # incomplete, so any member could disable auth for the entire app). Closing the
  # escalation path is the part that matters while there is no membership model; gating
  # ordinary deployment work would only cost usability without drawing a real boundary.
  #
  # The export endpoint travels with it: it dumps the instance's configuration as JSON.
  scope "/", HomelabWeb do
    pipe_through [:browser, :authenticated, :admin]

    live_session :admin,
      on_mount: [
        {HomelabWeb.Live.Hooks, :require_setup},
        {HomelabWeb.Live.Hooks, :require_auth},
        {HomelabWeb.Live.Hooks, :require_admin},
        {HomelabWeb.Live.Hooks, :notifications}
      ] do
      live "/settings", SettingsLive, :index
    end

    # Non-LiveView routes (controllers can't live inside a live_session).
    get "/settings/export", SettingsExportController, :export
  end

  # Health is deliberately public: a container HEALTHCHECK and the post-deploy smoke test
  # in PRODUCTION.md both call it before anyone could be logged in, and it reveals only
  # up/down per service plus the app version.
  scope "/api/v1", HomelabWeb.Api.V1 do
    pipe_through :api

    get "/health", HealthController, :index
  end

  # Everything else reads or MUTATES real state. This scope had no authentication at all
  # until now — and since the app's own Traefik rule matches `Host(base_domain)` with no
  # path constraint, all of it was served publicly. `POST /tenants/:id/deployments`
  # reaches `deploy_now/1`, and `image_override` takes any parseable reference, so this
  # was unauthenticated arbitrary-image execution on the Docker host.
  scope "/api/v1", HomelabWeb.Api.V1 do
    pipe_through [:api, :api_authenticated]

    resources "/tenants", TenantController, except: [:new, :edit] do
      resources "/deployments", DeploymentController, except: [:new, :edit]
    end

    resources "/app-templates", AppTemplateController, only: [:index, :show]
    resources "/backups", BackupController, only: [:index, :show, :create]
    post "/backups/:id/restore", BackupController, :restore
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
