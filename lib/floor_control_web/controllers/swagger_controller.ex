defmodule FloorControlWeb.SwaggerController do
  use FloorControlWeb, :controller
  require Logger

  def index(conn, _params) do
    send_asset(conn, "priv/static/swagger/index.html", "text/html")
  end

  def openapi(conn, _params) do
    send_asset(conn, "priv/static/openapi.yaml", "text/yaml")
  end

  defp send_asset(conn, relative_path, content_type) do
    path = Application.app_dir(:floor_control, relative_path)

    case File.read(path) do
      {:ok, body} ->
        conn
        |> put_resp_content_type(content_type)
        |> send_resp(200, body)

      {:error, reason} ->
        Logger.error("Documentation asset unavailable",
          asset_path: path,
          reason: inspect(reason)
        )

        send_missing_asset(conn)
    end
  end

  defp send_missing_asset(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "Documentation assets are not available")
  end
end
