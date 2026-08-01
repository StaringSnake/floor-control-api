defmodule FloorControlWeb.FloorControllerTest do
  use FloorControlWeb.ConnCase, async: false

  alias FloorControl.{FloorAuditEvent, FloorOwnership, Floors, Repo}

  setup _tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Repo, shared: true)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)
    :ok
  end

  test "obtains and releases a floor", %{conn: conn} do
    conn = post_json(conn, "/groups/group-1/floor", %{userId: "user-1"})

    assert json_response(conn, 200) == %{
             "message" => "Floor obtained by user-1 for group group-1"
           }

    conn = delete(build_conn(), "/groups/group-1/floor/user-1")

    assert json_response(conn, 200) == %{
             "message" => "Floor released by user-1 for group group-1"
           }
  end

  test "returns conflict for another user and forbidden for a non-holder release", %{conn: conn} do
    assert %{"message" => _} =
             conn |> post_json("/groups/group-1/floor", %{userId: "user-1"}) |> json_response(200)

    conn = post_json(conn, "/groups/group-1/floor", %{userId: "user-2"})
    assert json_response(conn, 409)["message"] =~ "currently held by user-1"

    conn = delete(build_conn(), "/groups/group-1/floor/user-2")
    assert json_response(conn, 403)["message"] =~ "does not hold"
  end

  test "same-holder obtain is idempotent over HTTP", %{conn: conn} do
    assert %{"message" => _} =
             conn |> post_json("/groups/group-1/floor", %{userId: "user-1"}) |> json_response(200)

    conn = post_json(conn, "/groups/group-1/floor", %{userId: "user-1", priority: 10})
    assert json_response(conn, 200)["message"] =~ "obtained by user-1"
    assert Repo.aggregate(FloorOwnership, :count) == 1
    assert Repo.aggregate(FloorAuditEvent, :count) == 1
  end

  test "returns bad request for invalid obtain bodies and identifiers", %{conn: conn} do
    for body <- [%{}, %{userId: "   "}, %{userId: "user-1", priority: 11}] do
      conn = post_json(conn, "/groups/group-1/floor", body)
      assert json_response(conn, 400)["message"]
    end

    conn = post_json(conn, "/groups/   /floor", %{userId: "user-1"})
    assert json_response(conn, 400)["message"] =~ "groupId"

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/groups/group-1/floor", "{invalid json")

    assert json_response(conn, 400) == %{"message" => "Bad Request"}
  end

  test "returns bad request for empty obtain bodies and invalid release identifiers", %{
    conn: conn
  } do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/groups/group-1/floor", "")

    assert json_response(conn, 400)["message"]

    conn = delete(build_conn(), "/groups/group-1/floor/%20%20")
    assert json_response(conn, 400)["message"] =~ "userId"

    conn = delete(build_conn(), "/groups/%20%20/floor/user-1")
    assert json_response(conn, 400)["message"] =~ "groupId"
  end

  test "omitted path segments remain standard not-found routes", %{conn: conn} do
    conn = delete(conn, "/groups/group-1/floor")
    assert json_response(conn, 404)["message"]

    conn = post_json(build_conn(), "/groups//floor", %{userId: "user-1"})
    assert json_response(conn, 404)["message"]
  end

  test "accepts 255-character identifiers and rejects longer HTTP identifiers", %{conn: conn} do
    valid_id = String.duplicate("a", 255)
    oversized_id = valid_id <> "a"

    conn = post_json(conn, "/groups/#{valid_id}/floor", %{userId: valid_id})
    assert json_response(conn, 200)["message"]

    conn = post_json(build_conn(), "/groups/#{oversized_id}/floor", %{userId: valid_id})
    assert json_response(conn, 400)["message"] =~ "groupId"

    conn = post_json(build_conn(), "/groups/group-1/floor", %{userId: oversized_id})
    assert json_response(conn, 400)["message"] =~ "userId"
  end

  test "accepts 255-character release identifiers and rejects longer release identifiers", %{
    conn: conn
  } do
    valid_id = String.duplicate("r", 255)
    oversized_id = valid_id <> "r"

    assert {:ok, _ownership} = Floors.obtain(valid_id, %{user_id: valid_id})

    conn = delete(conn, "/groups/#{valid_id}/floor/#{valid_id}")
    assert json_response(conn, 200)["message"] =~ "released by"

    conn = delete(build_conn(), "/groups/#{oversized_id}/floor/#{valid_id}")
    assert json_response(conn, 400)["message"] =~ "groupId"

    conn = delete(build_conn(), "/groups/#{valid_id}/floor/#{oversized_id}")
    assert json_response(conn, 400)["message"] =~ "userId"
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end
end
