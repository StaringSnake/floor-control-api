defmodule FloorControlWeb.Router do
  use FloorControlWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", FloorControlWeb do
    pipe_through :api
    get "/", HealthController, :index
    get "/ready", HealthController, :ready
    get "/groups/:groupId/floor", FloorController, :current_holder
    get "/groups/:groupId/floor/history", FloorController, :history
    post "/groups/:groupId/floor", FloorController, :obtain
    delete "/groups/:groupId/floor/:userId", FloorController, :release
  end
end
