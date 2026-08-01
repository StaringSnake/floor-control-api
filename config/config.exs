import Config

config :floor_control, ecto_repos: [FloorControl.Repo]
config :floor_control, :floor_timeout_ms, 30_000

config :floor_control, FloorControlWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  render_errors: [formats: [json: FloorControlWeb.ErrorJSON], layout: false],
  pubsub_server: FloorControl.PubSub

config :phoenix, :json_library, Jason
config :logger, :console, format: "$time $metadata[$level] $message\n", metadata: [:request_id]

import_config "#{config_env()}.exs"
