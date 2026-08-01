defmodule FloorControl.FloorsTest do
  use FloorControl.DataCase, async: false

  alias FloorControl.{FloorAuditEvent, FloorOwnership, Floors}

  test "obtains an unoccupied floor and records one audit event" do
    assert {:ok, %FloorOwnership{group_id: "group-1", user_id: "user-1"}} =
             Floors.obtain(" group-1 ", %{"userId" => " user-1 "})

    assert Repo.aggregate(FloorOwnership, :count) == 1
    assert Repo.aggregate(FloorAuditEvent, :count) == 1
  end

  test "same holder obtain is idempotent and does not add an audit event" do
    assert {:ok, first} = Floors.obtain("group-1", %{user_id: "user-1"})
    assert {:ok, second} = Floors.obtain("group-1", %{user_id: "user-1", priority: 10})

    assert first.id == second.id
    assert Repo.aggregate(FloorAuditEvent, :count) == 1
  end

  test "another holder at any priority receives a conflict" do
    assert {:ok, _ownership} = Floors.obtain("group-1", %{user_id: "user-1", priority: 10})

    assert {:error, :conflict, %{user_id: "user-1"}} =
             Floors.obtain("group-1", %{user_id: "user-2"})

    assert Repo.aggregate(FloorAuditEvent, :count) == 1
  end

  test "only the current holder can release and release records an audit event" do
    assert {:ok, _ownership} = Floors.obtain("group-1", %{user_id: "user-1"})
    assert {:error, :forbidden} = Floors.release("group-1", "user-2")
    assert Repo.aggregate(FloorAuditEvent, :count) == 1

    assert {:ok, %{user_id: "user-1"}} = Floors.release("group-1", "user-1")
    assert Repo.aggregate(FloorOwnership, :count) == 0
    assert Repo.aggregate(FloorAuditEvent, :count) == 2
  end

  test "invalid identifiers and priorities return validation errors" do
    assert {:error, {:validation, _}} = Floors.obtain("   ", %{"userId" => "user-1"})
    assert {:error, {:validation, _}} = Floors.obtain("group-1", %{"userId" => "   "})

    assert {:error, {:validation, _}} =
             Floors.obtain("group-1", %{"userId" => "user-1", "priority" => 11})

    assert {:error, {:validation, _}} = Floors.obtain("group-1", nil)
  end

  test "accepts 255-character identifiers and rejects longer obtain and release identifiers" do
    valid_id = String.duplicate("a", 255)
    oversized_id = valid_id <> "a"

    assert {:ok, _ownership} = Floors.obtain(valid_id, %{user_id: valid_id})
    assert {:ok, _ownership} = Floors.release(valid_id, valid_id)
    assert {:error, {:validation, _}} = Floors.obtain(oversized_id, %{user_id: valid_id})
    assert {:error, {:validation, _}} = Floors.obtain(valid_id, %{user_id: oversized_id})
    assert {:error, {:validation, _}} = Floors.release(oversized_id, valid_id)
    assert {:error, {:validation, _}} = Floors.release(valid_id, oversized_id)
  end

  test "concurrent obtains leave one owner and one audit transition" do
    for group_number <- 1..10 do
      group_id = "different-user-group-#{group_number}"
      results = concurrent_obtains(group_id, ["user-1", "user-2"])

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :conflict, _}, &1)) == 1
      assert ownership_count(group_id) == 1
      assert audit_count(group_id) == 1
    end
  end

  test "simultaneous obtains by the same holder both succeed idempotently" do
    for group_number <- 1..10 do
      group_id = "same-user-group-#{group_number}"
      results = concurrent_obtains(group_id, ["user-1", "user-1"])

      assert Enum.count(results, &match?({:ok, _}, &1)) == 2
      assert ownership_count(group_id) == 1
      assert audit_count(group_id) == 1
    end
  end

  defp concurrent_obtains(group_id, user_ids) do
    parent = self()

    tasks =
      for user_id <- user_ids do
        task =
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :start -> Floors.obtain(group_id, %{user_id: user_id})
            end
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
        task
      end

    for _task <- tasks, do: assert_receive({:ready, _pid})
    Enum.each(tasks, &send(&1.pid, :start))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp ownership_count(group_id) do
    FloorOwnership
    |> where([ownership], ownership.group_id == ^group_id)
    |> Repo.aggregate(:count)
  end

  defp audit_count(group_id) do
    FloorAuditEvent
    |> where([event], event.group_id == ^group_id)
    |> Repo.aggregate(:count)
  end
end
