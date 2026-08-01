import Config

config :floor_control, FloorControl.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  database: System.get_env("DATABASE_NAME", "floor_control_dev"),
  show_sensitive_data_on_connection_error: true,
  stacktrace: true

config :floor_control, FloorControlWeb.Endpoint,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-only-secret-key-base-for-floor-control-api"

config :phoenix, :plug_init_mode, :runtime
