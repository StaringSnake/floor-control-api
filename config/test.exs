import Config

config :floor_control, FloorControl.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  database: System.get_env("DATABASE_NAME", "floor_control_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :floor_control, FloorControlWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false,
  secret_key_base: "test-only-secret-key-base-for-floor-control-api"

config :logger, level: :warning
