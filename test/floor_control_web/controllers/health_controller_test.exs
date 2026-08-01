defmodule FloorControlWeb.HealthControllerTest do
  use FloorControlWeb.ConnCase

  test "GET / returns a healthy JSON response", %{conn: conn} do
    conn = get(conn, "/")
    assert response(conn, 200) == ~s({"status":"ok"})
  end

  test "database readiness reports ready when the database responds" do
    assert FloorControl.Health.database_status(__MODULE__.ReadyRepo) == :ok
  end

  test "database readiness reports unavailable when the database cannot be reached" do
    assert FloorControl.Health.database_status(__MODULE__.UnavailableRepo) == :unavailable
  end

  test "GET /ready returns ready when the database responds", %{conn: conn} do
    Application.put_env(:floor_control, :health_repo, __MODULE__.ReadyRepo)
    on_exit(fn -> Application.delete_env(:floor_control, :health_repo) end)

    conn = get(conn, "/ready")
    assert response(conn, 200) == ~s({"status":"ok"})
  end

  test "GET /ready returns service unavailable when the database cannot be reached", %{
    conn: conn
  } do
    Application.put_env(:floor_control, :health_repo, __MODULE__.UnavailableRepo)
    on_exit(fn -> Application.delete_env(:floor_control, :health_repo) end)

    conn = get(conn, "/ready")
    assert response(conn, 503) == ~s({"status":"unavailable"})
  end

  defmodule ReadyRepo do
    def query("SELECT 1", [], _opts), do: {:ok, :result}
  end

  defmodule UnavailableRepo do
    def query("SELECT 1", [], _opts), do: {:error, :connection_error}
  end
end
