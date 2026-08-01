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

  test "looks up an occupied floor with its current holder", %{conn: conn} do
    assert {:ok, ownership} = Floors.obtain("group-1", %{user_id: "user-1", priority: 7})

    conn = get(conn, "/groups/group-1/floor")

    assert json_response(conn, 200) == %{
             "holder" => %{
               "userId" => "user-1",
               "priority" => 7,
               "acquiredAt" => DateTime.to_iso8601(ownership.acquired_at)
             }
           }

    assert Repo.aggregate(FloorAuditEvent, :count) == 1
  end

  test "looks up an unoccupied floor as a nullable holder", %{conn: conn} do
    assert json_response(get(conn, "/groups/group-1/floor"), 200) == %{"holder" => nil}
  end

  test "returns an empty paginated history", %{conn: conn} do
    assert json_response(get(conn, "/groups/group-1/floor/history"), 200) == %{
             "events" => [],
             "nextPageToken" => nil
           }
  end

  test "returns every transition and provenance in chronological order", %{conn: conn} do
    assert {:ok, ownership} = Floors.obtain("group-1", %{user_id: "user-1", priority: 3})
    assert {:ok, _} = Floors.release("group-1", "user-1")
    assert {:ok, _} = Floors.obtain("group-1", %{user_id: "user-2", priority: 2})
    assert {:ok, _} = Floors.obtain("group-1", %{user_id: "user-3", priority: 7})

    assert {:ok, 1, false} =
             Floors.expire_expired(
               DateTime.add(ownership.acquired_at, 31_000, :millisecond),
               30_000
             )

    response = json_response(get(conn, "/groups/group-1/floor/history"), 200)

    assert Enum.map(response["events"], & &1["transition"]) ==
             ["acquired", "released", "acquired", "preempted", "acquired", "timed_out"]

    assert Enum.at(response["events"], 3)["counterparty"] == %{
             "userId" => "user-3",
             "priority" => 7
           }

    assert Enum.at(response["events"], 4)["counterparty"] == %{
             "userId" => "user-2",
             "priority" => 2
           }

    assert Enum.all?(
             response["events"],
             &(is_binary(&1["occurredAt"]) and is_binary(&1["recordedAt"]))
           )

    assert response["nextPageToken"] == nil
  end

  test "pages without duplicates and applies keyset tie-breaking", %{conn: conn} do
    occurred_at = ~U[2026-08-01 12:00:00.000001Z]

    for user_id <- ["user-1", "user-2", "user-3"] do
      %FloorAuditEvent{}
      |> FloorAuditEvent.changeset(%{
        group_id: "group-1",
        user_id: user_id,
        event_type: "acquired",
        priority: 1,
        occurred_at: occurred_at
      })
      |> Repo.insert!()
    end

    first = json_response(get(conn, "/groups/group-1/floor/history?pageSize=2"), 200)
    assert Enum.map(first["events"], & &1["userId"]) == ["user-1", "user-2"]
    assert is_binary(first["nextPageToken"])

    second =
      get(
        build_conn(),
        "/groups/group-1/floor/history?pageSize=2&pageToken=#{first["nextPageToken"]}"
      )
      |> json_response(200)

    assert Enum.map(second["events"], & &1["userId"]) == ["user-3"]
    assert second["nextPageToken"] == nil
  end

  test "keeps a stable snapshot across page interleaving with a backdated append", %{conn: conn} do
    for {user_id, seconds} <- [{"user-1", 1}, {"user-2", 2}, {"user-3", 3}] do
      insert_history_event(
        "group-1",
        user_id,
        DateTime.add(~U[2026-08-01 12:00:00Z], seconds, :second)
      )
    end

    first = json_response(get(conn, "/groups/group-1/floor/history?pageSize=2"), 200)
    assert Enum.map(first["events"], & &1["userId"]) == ["user-1", "user-2"]

    insert_history_event("group-1", "late-earlier", ~U[2026-08-01 11:00:00Z])

    second =
      get(
        build_conn(),
        "/groups/group-1/floor/history?pageSize=2&pageToken=#{first["nextPageToken"]}"
      )
      |> json_response(200)

    assert Enum.map(second["events"], & &1["userId"]) == ["user-3"]

    fresh = json_response(get(build_conn(), "/groups/group-1/floor/history?pageSize=2"), 200)
    assert hd(fresh["events"])["userId"] == "late-earlier"
  end

  test "rejects oversized, malformed, and out-of-range page tokens", %{} do
    timestamp = DateTime.to_iso8601(~U[2026-08-01 12:00:00.000001Z])
    maximum = 9_223_372_036_854_775_807

    invalid_payloads = [
      %{"occurredAt" => timestamp, "id" => 1},
      %{
        "occurredAt" => timestamp,
        "id" => 1,
        "highWaterEventId" => 1,
        "groupId" => "group-1",
        "extra" => true
      },
      %{
        "occurredAt" => timestamp,
        "id" => maximum + 1,
        "highWaterEventId" => maximum,
        "groupId" => "group-1"
      },
      %{
        "occurredAt" => timestamp,
        "id" => 1,
        "highWaterEventId" => maximum + 1,
        "groupId" => "group-1"
      },
      %{"occurredAt" => timestamp, "id" => 2, "highWaterEventId" => 1, "groupId" => "group-1"},
      %{"occurredAt" => timestamp, "id" => 1, "highWaterEventId" => 1, "groupId" => " "}
    ]

    for payload <- invalid_payloads do
      token = encode_page_token(payload)

      assert json_response(
               get(build_conn(), "/groups/group-1/floor/history?pageToken=#{token}"),
               400
             )["message"] == "pageToken is invalid"
    end

    oversized_token = String.duplicate("A", 513)

    assert json_response(
             get(build_conn(), "/groups/group-1/floor/history?pageToken=#{oversized_token}"),
             400
           )["message"] == "pageToken is invalid"
  end

  test "rejects a page token issued for a different group", %{conn: conn} do
    insert_history_event("group-a", "user-1", ~U[2026-08-01 12:00:00Z])
    insert_history_event("group-a", "user-2", ~U[2026-08-01 12:00:01Z])

    first = json_response(get(conn, "/groups/group-a/floor/history?pageSize=1"), 200)

    assert json_response(
             get(
               build_conn(),
               "/groups/group-b/floor/history?pageSize=1&pageToken=#{first["nextPageToken"]}"
             ),
             400
           )["message"] == "pageToken is invalid"
  end

  test "paginates a maximum-length group identifier", %{conn: conn} do
    group_id = String.duplicate("g", 255)
    insert_history_event(group_id, "user-1", ~U[2026-08-01 12:00:00Z])
    insert_history_event(group_id, "user-2", ~U[2026-08-01 12:00:01Z])

    first = json_response(get(conn, "/groups/#{group_id}/floor/history?pageSize=1"), 200)
    assert is_binary(first["nextPageToken"])
    assert byte_size(first["nextPageToken"]) <= 2_048

    second =
      get(
        build_conn(),
        "/groups/#{group_id}/floor/history?pageSize=1&pageToken=#{first["nextPageToken"]}"
      )
      |> json_response(200)

    assert Enum.map(second["events"], & &1["userId"]) == ["user-2"]
    assert second["nextPageToken"] == nil
  end

  test "paginates a 255-character multibyte group identifier", %{conn: conn} do
    group_id = String.duplicate("😀", 255)
    encoded_group_id = URI.encode(group_id, &URI.char_unreserved?/1)
    insert_history_event(group_id, "unicode-user-1", ~U[2026-08-01 12:00:00Z])
    insert_history_event(group_id, "unicode-user-2", ~U[2026-08-01 12:00:01Z])

    first =
      json_response(get(conn, "/groups/#{encoded_group_id}/floor/history?pageSize=1"), 200)

    assert is_binary(first["nextPageToken"])
    assert byte_size(first["nextPageToken"]) <= 2_048

    second =
      get(
        build_conn(),
        "/groups/#{encoded_group_id}/floor/history?pageSize=1&pageToken=#{first["nextPageToken"]}"
      )
      |> json_response(200)

    assert Enum.map(second["events"], & &1["userId"]) == ["unicode-user-2"]
    assert second["nextPageToken"] == nil
  end

  test "isolates history by group and rejects invalid pagination parameters", %{conn: conn} do
    assert {:ok, _} = Floors.obtain("group-1", %{user_id: "user-1"})
    assert {:ok, _} = Floors.obtain("group-2", %{user_id: "user-2"})

    assert [%{"groupId" => "group-1"}] =
             get(conn, "/groups/group-1/floor/history")
             |> json_response(200)
             |> Map.fetch!("events")

    for query <- ["pageSize=0", "pageSize=101", "pageSize=1.5", "pageSize=abc", "pageToken=bad"] do
      assert json_response(get(build_conn(), "/groups/group-1/floor/history?#{query}"), 400)[
               "message"
             ]
    end
  end

  test "uses the default and maximum page size", %{conn: conn} do
    for index <- 1..101 do
      %FloorAuditEvent{}
      |> FloorAuditEvent.changeset(%{
        group_id: "group-1",
        user_id: "user-#{index}",
        event_type: "acquired",
        occurred_at: DateTime.add(~U[2026-08-01 12:00:00Z], index, :second)
      })
      |> Repo.insert!()
    end

    assert length(json_response(get(conn, "/groups/group-1/floor/history"), 200)["events"]) == 50

    assert length(
             json_response(get(build_conn(), "/groups/group-1/floor/history?pageSize=100"), 200)[
               "events"
             ]
           ) == 100
  end

  test "returns exactly 205 events across 100-event pages without sentinel leakage", %{
    conn: conn
  } do
    expected_ids =
      for index <- 1..205 do
        insert_history_event(
          "group-1",
          "user-#{index}",
          DateTime.add(~U[2026-08-01 12:00:00Z], index, :second)
        ).id
      end

    {page_ids, next_page_token} = fetch_history_page(conn, 100, nil)
    assert length(page_ids) == 100
    assert is_binary(next_page_token)

    {second_page_ids, next_page_token} = fetch_history_page(build_conn(), 100, next_page_token)
    assert length(second_page_ids) == 100
    assert is_binary(next_page_token)

    {last_page_ids, nil} = fetch_history_page(build_conn(), 100, next_page_token)
    assert length(last_page_ids) == 5

    assert Enum.uniq(page_ids ++ second_page_ids ++ last_page_ids) ==
             page_ids ++ second_page_ids ++ last_page_ids

    assert page_ids ++ second_page_ids ++ last_page_ids == expected_ids
  end

  test "lookup returns an empty holder after release and timeout", %{conn: conn} do
    assert {:ok, _ownership} = Floors.obtain("group-1", %{user_id: "user-1"})
    assert {:ok, _} = Floors.release("group-1", "user-1")
    assert json_response(get(conn, "/groups/group-1/floor"), 200) == %{"holder" => nil}

    assert {:ok, ownership} = Floors.obtain("group-2", %{user_id: "user-2"})

    assert {:ok, 1, false} =
             Floors.expire_expired(
               DateTime.add(ownership.acquired_at, 31_000, :millisecond),
               30_000
             )

    assert json_response(get(build_conn(), "/groups/group-2/floor"), 200) == %{"holder" => nil}
  end

  test "returns conflict for another user and forbidden for a non-holder release", %{conn: conn} do
    assert %{"message" => _} =
             conn |> post_json("/groups/group-1/floor", %{userId: "user-1"}) |> json_response(200)

    conn = post_json(conn, "/groups/group-1/floor", %{userId: "user-2"})
    assert json_response(conn, 409)["message"] =~ "currently held by user-1"

    conn = delete(build_conn(), "/groups/group-1/floor/user-2")
    assert json_response(conn, 403)["message"] =~ "does not hold"
  end

  test "preempts over HTTP only with a strictly higher priority", %{conn: conn} do
    assert %{"message" => _} =
             conn
             |> post_json("/groups/group-1/floor", %{userId: "user-1", priority: 3})
             |> json_response(200)

    conn = post_json(conn, "/groups/group-1/floor", %{userId: "user-2", priority: 7})
    assert json_response(conn, 200)["message"] =~ "obtained by user-2"

    conn = post_json(build_conn(), "/groups/group-1/floor", %{userId: "user-3", priority: 7})
    assert json_response(conn, 409)["message"] =~ "currently held by user-2"
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

  test "returns bad request for invalid lookup identifiers", %{conn: conn} do
    assert json_response(get(conn, "/groups/%20%20/floor"), 400)["message"] =~ "groupId"

    oversized_id = String.duplicate("a", 256)

    assert json_response(get(build_conn(), "/groups/#{oversized_id}/floor"), 400)["message"] =~
             "groupId"
  end

  test "omitted lookup path segments remain standard not-found routes", %{conn: conn} do
    assert json_response(get(conn, "/groups/group-1"), 404)["message"]
    assert json_response(get(build_conn(), "/groups//floor"), 404)["message"]
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

  defp insert_history_event(group_id, user_id, occurred_at) do
    %FloorAuditEvent{}
    |> FloorAuditEvent.changeset(%{
      group_id: group_id,
      user_id: user_id,
      event_type: "acquired",
      priority: 1,
      occurred_at: occurred_at
    })
    |> Repo.insert!()
  end

  defp encode_page_token(payload) do
    payload
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp fetch_history_page(conn, page_size, page_token) do
    query =
      case page_token do
        nil -> "pageSize=#{page_size}"
        page_token -> "pageSize=#{page_size}&pageToken=#{page_token}"
      end

    response = get(conn, "/groups/group-1/floor/history?#{query}") |> json_response(200)
    {Enum.map(response["events"], & &1["eventId"]), response["nextPageToken"]}
  end
end
