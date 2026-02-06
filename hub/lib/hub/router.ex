defmodule Hub.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :admin_auth do
    plug Hub.Plugs.AdminAuth
    plug Hub.Plugs.RateLimit
  end

  pipeline :metrics do
    plug :accepts, ["text", "html"]
  end

  scope "/api", Hub do
    pipe_through :api
    get "/health", HealthController, :index
  end

  scope "/api/v1", Hub do
    pipe_through [:api, :admin_auth]

    get "/tenants/:id", TenantController, :show
    patch "/tenants/:id", TenantController, :update
    get "/tenants/:id/usage", TenantController, :usage

    resources "/fleets", FleetController, only: [:index, :create, :show, :delete]
    resources "/keys", KeyController, only: [:index, :create, :delete]
    resources "/agents", AgentController, only: [:index, :show, :delete]
  end

  scope "/", Hub do
    pipe_through :metrics
    get "/metrics", MetricsController, :index
  end
end
