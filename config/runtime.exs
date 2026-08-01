import Config

if config_env() == :prod do
  floor_timeout_ms =
    System.get_env("FLOOR_TIMEOUT_SECONDS", "30")
    |> FloorControl.FloorTimeout.parse_timeout_seconds!()

  config :floor_control, :floor_timeout_ms, floor_timeout_ms

  database_url = System.get_env("DATABASE_URL") || raise "DATABASE_URL is missing"
  secret_key_base = System.get_env("SECRET_KEY_BASE") || raise "SECRET_KEY_BASE is missing"
  host = System.get_env("PHX_HOST", "localhost")
  port = String.to_integer(System.get_env("PORT", "4000"))

  database_ssl =
    case System.get_env("DATABASE_SSL", "true") do
      "true" -> true
      "false" -> false
      value -> raise "DATABASE_SSL must be either true or false, got: #{value}"
    end

  database_options = [
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  ]

  database_options =
    if database_ssl do
      ca_cert_file =
        System.get_env("DATABASE_CA_CERT_FILE") ||
          raise "DATABASE_CA_CERT_FILE is required when DATABASE_SSL=true"

      ssl_server_name =
        System.get_env("DATABASE_SSL_SERVER_NAME") ||
          raise "DATABASE_SSL_SERVER_NAME is required when DATABASE_SSL=true"

      unless File.exists?(ca_cert_file) do
        raise "DATABASE_CA_CERT_FILE does not exist: #{ca_cert_file}"
      end

      Keyword.put(database_options, :ssl,
        verify: :verify_peer,
        cacertfile: ca_cert_file,
        server_name_indication: String.to_charlist(ssl_server_name),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      )
    else
      Keyword.put(database_options, :ssl, false)
    end

  config :floor_control, FloorControl.Repo, database_options

  config :floor_control, FloorControlWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end
