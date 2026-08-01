defmodule FloorControlWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :floor_control

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug Plug.Parsers, parsers: [:urlencoded, :multipart, :json], json_decoder: Jason
  plug Plug.MethodOverride
  plug Plug.Head
  plug FloorControlWeb.Router
end
