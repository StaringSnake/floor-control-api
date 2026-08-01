defmodule FloorControlWeb.Router do
  use FloorControlWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FloorControlWeb do
    pipe_through :api
    get "/", HealthController, :index
    get "/ready", HealthController, :ready
  end
end
