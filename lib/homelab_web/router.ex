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

  pipeline :api_admin do
    plug HomelabWeb.Plugs.RequireAdminApi
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

  # A member can LOOK. The split below is read vs. write: everything here renders state
  # the operator already owns, and none of it is where privilege is granted or where the
  # box is changed.
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
      live "/deployments/:id", DeploymentLive, :show
      live "/domains", DomainsLive, :index
      live "/backups", BackupsLive, :index
      live "/activity", ActivityLive, :index
      live "/telemetry", TelemetryLive, :index
    end
  end

  # An administrator can CHANGE things.
  #
  # `/settings` is the one that matters most: it is where privilege is granted (the role
  # dropdown), where the identity provider is pointed (repoint `oidc_issuer` at an IdP
  # you control and you own the next login), and where authentication itself can be
  # switched back off (`rerun_setup` deletes `setup_completed`, and RequireAuth
  # deliberately fails open while setup is incomplete). `/settings/export` travels with
  # it because it dumps the instance's configuration as JSON.
  #
  # The rest create or reconfigure real infrastructure: `/deploy/new` and `/workbench`
  # both end in running a container image on the Docker host, and `/tenants/:id` is where
  # a space and its deployments are edited and destroyed.
  #
  # `/storage` and `/containers` are here for a subtler reason than the others — most of
  # what they render is read-only. But `/storage` creates and deletes named volumes and
  # rewrites a live deployment's mounts (a wrong path there is data loss, not a bad
  # render), and `/containers` reads EVERY container on the daemon rather than only the
  # ones we manage: the image, command, and labels of the operator's unrelated stacks.
  # Both are admin-shaped even where the page looks like a table.
  #
  # Note what this is NOT. With no user<->tenant relationship in the schema, admin/member
  # is the only boundary that exists — it is read-vs-write, not tenant isolation. A
  # member can still see every tenant's state.
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
      live "/workbench", WorkbenchLive, :index
      live "/storage", StorageLive, :index
      live "/containers", ContainersLive, :index
      live "/deploy/new", DeployWizardLive, :new
      live "/tenants/:id", TenantLive, :show
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
  # Reads: any signed-in user. Backups nest under the tenant like everything else —
  # top-level `/backups` meant `index` listed every tenant's jobs and `show`/`restore`
  # took a bare id, so any signed-in user could read all backup history and restore any
  # tenant's snapshot over `/data/restore`. The old paths are removed rather than kept
  # as aliases; left in place they would simply be a bypass of the scoping.
  scope "/api/v1", HomelabWeb.Api.V1 do
    pipe_through [:api, :api_authenticated]

    resources "/tenants", TenantController, only: [:index, :show] do
      resources "/deployments", DeploymentController, only: [:index, :show]
      resources "/backups", BackupController, only: [:index, :show]
    end

    resources "/app-templates", AppTemplateController, only: [:index, :show]
  end

  # Writes: administrators. `POST /tenants/:id/deployments` reaches `deploy_now/1` and
  # `image_override` accepts any parseable reference, so a write here is arbitrary-image
  # execution on the Docker host; `DELETE` destroys real infrastructure and
  # `POST /backups/:id/restore` overwrites live data from a snapshot. Listing what is
  # deployed does none of that, which is where the line is drawn.
  #
  # Separate pipeline, not the browser one: `RequireAdmin` refuses with a 302 to `/`,
  # which `curl` follows and reports as a 200 full of HTML, so a script could not tell
  # refused from succeeded. `RequireAdminApi` answers 403 JSON.
  scope "/api/v1", HomelabWeb.Api.V1 do
    pipe_through [:api, :api_authenticated, :api_admin]

    resources "/tenants", TenantController, only: [:create, :update, :delete] do
      resources "/deployments", DeploymentController, only: [:create, :update, :delete]
      resources "/backups", BackupController, only: [:create]
      post "/backups/:id/restore", BackupController, :restore
    end
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
