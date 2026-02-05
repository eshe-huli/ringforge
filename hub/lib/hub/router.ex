defmodule Hub.Router do
  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :metrics do
    plug :accepts, ["text", "html"]
  end

  scope "/api", Hub do
    pipe_through :api
    get "/health", HealthController, :index
  end

  scope "/", Hub do
    pipe_through :metrics
    get "/metrics", MetricsController, :index
  end
end
