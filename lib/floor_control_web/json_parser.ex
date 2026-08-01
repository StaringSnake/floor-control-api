defmodule FloorControlWeb.JSONParser do
  @parser_options [parsers: [:urlencoded, :multipart, :json], json_decoder: Jason]

  def init(_opts), do: Plug.Parsers.init(@parser_options)

  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    _error in Plug.Parsers.ParseError ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{message: "Bad Request"}))
      |> Plug.Conn.halt()
  end
end
