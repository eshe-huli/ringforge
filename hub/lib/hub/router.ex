defmodule Hub.Router do
  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :stripe_webhook do
    plug :accepts, ["json"]
    plug Hub.Plugs.RawBodyReader
  end

  pipeline :admin_auth do
    plug Hub.Plugs.AdminAuth
    plug Hub.Plugs.RateLimit
  end

  pipeline :metrics do
    plug :accepts, ["text", "html"]
  end

  pipeline :auth_rate_limited do
    plug Hub.Plugs.RateLimiter, scope: :auth
  end

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {Hub.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Stripe webhook (no CSRF, no auth — signature verified in controller)
  scope "/webhooks", Hub do
    pipe_through :stripe_webhook
    post "/stripe", WebhookController, :stripe
  end

  # Billing (session auth)
  scope "/billing", Hub do
    pipe_through :browser
    post "/checkout", BillingController, :checkout
    get "/portal", BillingController, :portal
  end

  scope "/api", Hub do
    pipe_through :api
    get "/health", HealthController, :index
    get "/connect/check", ConnectController, :check
    post "/auth/challenge", ChallengeController, :create
  end

  # Cluster health — admin-only
  scope "/api/cluster", Hub do
    pipe_through [:api, :admin_auth]
    get "/health", ClusterController, :health
  end

  scope "/api/v1", Hub do
    pipe_through [:api, :admin_auth]

    get "/tenants/:id", TenantController, :show
    patch "/tenants/:id", TenantController, :update
    get "/tenants/:id/usage", TenantController, :usage

    resources "/fleets", FleetController, only: [:index, :create, :show, :update, :delete]
    post "/fleets/:fleet_id/agents/:agent_id", FleetController, :assign_agent
    post "/fleets/:fleet_id/squads", FleetController, :create_squad
    post "/squads/:squad_id/agents/:agent_id", FleetController, :assign_agent_to_squad
    delete "/squads/:squad_id/agents/:agent_id", FleetController, :remove_agent_from_squad
    resources "/keys", KeyController, only: [:index, :create, :delete]
    resources "/agents", AgentController, only: [:index, :show, :update, :delete]
    post "/agents/cleanup", AgentController, :cleanup

    # Billing API (authenticated)
    get "/billing/plans", BillingApiController, :plans
    get "/billing/subscription", BillingApiController, :subscription
    post "/billing/checkout", BillingApiController, :checkout
    post "/billing/portal", BillingApiController, :portal

    # Webhooks API (authenticated)
    resources "/webhooks", WebhookApiController, only: [:index, :create, :show, :update, :delete]
    post "/webhooks/:id/test", WebhookApiController, :test

    # Provisioning API (authenticated)
    post "/providers", ProvisioningController, :create_credential
    get "/providers", ProvisioningController, :list_credentials
    delete "/providers/:id", ProvisioningController, :delete_credential
    get "/providers/regions/:provider", ProvisioningController, :list_regions
    get "/providers/sizes/:provider", ProvisioningController, :list_sizes

    post "/agents/provision", ProvisioningController, :provision_agent
    get "/agents/provision", ProvisioningController, :list_agents
    delete "/agents/provision/:id", ProvisioningController, :destroy_agent
    get "/agents/provision/:id/status", ProvisioningController, :agent_status
  end

  scope "/", Hub do
    pipe_through [:metrics, :admin_auth]
    get "/metrics", MetricsController, :index
  end

  scope "/auth", Hub do
    pipe_through [:browser, :auth_rate_limited]
    post "/register", SessionController, :register
    post "/login", SessionController, :login
    post "/api-key", SessionController, :api_key_login
    get "/logout", SessionController, :logout

    # Magic link
    post "/magic-link", AuthController, :magic_link_send
    get "/magic-link/:token", AuthController, :magic_link_verify

    # OAuth (Ueberauth)
    get "/:provider", AuthController, :request
    get "/:provider/callback", AuthController, :callback
  end

  scope "/", Hub do
    pipe_through :browser
    get "/", RedirectController, :to_dashboard
  end

  scope "/", Hub.Live do
    pipe_through :browser
    live "/dashboard", DashboardLive
    live "/dashboard/metrics", MetricsLive
    live "/billing", BillingLive
    live "/webhooks", WebhooksLive
    live "/invites", InvitesLive
    live "/provisioning", ProvisioningLive
    live "/devices", DevicesLive
    live "/audit", AuditLive
  end
end
