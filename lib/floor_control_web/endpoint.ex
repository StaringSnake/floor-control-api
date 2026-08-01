defmodule FloorControlWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :floor_control

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Static,
    at: "/",
    from: :floor_control,
    only_matching: ["swagger"],
    cache_control_for_etags: "no-cache"

  plug FloorControlWeb.JSONParser
  plug Plug.MethodOverride
  plug Plug.Head
  plug FloorControlWeb.Router
end
