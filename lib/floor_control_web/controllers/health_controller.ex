defmodule FloorControlWeb.HealthController do
  use FloorControlWeb, :controller

  def index(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    case FloorControl.Health.database_status() do
      :ok ->
        json(conn, %{status: "ok"})

      :unavailable ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable"})
    end
  end
end
