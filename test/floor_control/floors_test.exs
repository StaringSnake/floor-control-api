defmodule FloorControl.FloorsTest do
  use FloorControl.DataCase, async: false

  alias FloorControl.{FloorAuditEvent, FloorOwnership, FloorTimeout, Floors}

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
    assert first.acquired_at == second.acquired_at
    assert Repo.aggregate(FloorAuditEvent, :count) == 1
  end

  test "automatic mailbox sweep releases expired ownership and preserves a fresh owner" do
    now = ~U[2026-08-01 12:00:00.000001Z]
    assert {:ok, ownership} = Floors.obtain("group-1", %{user_id: "user-1"})

    ownership
    |> FloorOwnership.changeset(%{acquired_at: DateTime.add(now, -2_000, :millisecond)})
    |> Repo.update!()

    assert {:ok, fresh} = Floors.obtain("group-2", %{user_id: "fresh-user"})

    fresh
    |> FloorOwnership.changeset(%{acquired_at: now})
    |> Repo.update!()

    pid =
      start_supervised!({
        FloorTimeout,
        [name: nil, timeout_ms: 1_000, interval_ms: 10, schedule?: false, clock: fn -> now end]
      })

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    assert :ok = FloorTimeout.arm(pid)

    assert eventually(fn -> Repo.get(FloorOwnership, ownership.id) == nil end)
    assert Repo.get(FloorOwnership, fresh.id)
    assert Repo.get_by(FloorAuditEvent, event_type: "timed_out", group_id: "group-1")
    assert {:ok, %{user_id: "user-2"}} = Floors.obtain("group-1", %{user_id: "user-2"})
  end

  test "repeated arm calls keep one automatic sweep chain" do
    parent = self()

    pid =
      start_supervised!({
        FloorTimeout,
        [
          name: nil,
          timeout_ms: 1_000,
          interval_ms: 100,
          schedule?: false,
          notify: fn result -> send(parent, {:timeout_sweep, result}) end
        ]
      })

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    assert :ok = FloorTimeout.arm(pid)
    assert :ok = FloorTimeout.arm(pid)

    assert_receive {:timeout_sweep, {:normal, 0}}, 1_000
    refute_receive {:timeout_sweep, _result}, 30
  end

  test "supervised timeout restart recovers an expired persisted ownership" do
    now = ~U[2026-08-01 12:00:00Z]
    assert {:ok, ownership} = Floors.obtain("group-1", %{user_id: "user-1"})

    ownership
    |> FloorOwnership.changeset(%{acquired_at: DateTime.add(now, -2_000, :millisecond)})
    |> Repo.update!()

    child_spec =
      Supervisor.child_spec(
        {FloorTimeout,
         [
           name: nil,
           timeout_ms: 1_000,
           interval_ms: 10,
           schedule?: false,
           clock: fn -> now end
         ]},
        id: FloorTimeout
      )

    supervisor_spec = %{
      id: :floor_timeout_test_supervisor,
      start: {Supervisor, :start_link, [[child_spec], [strategy: :one_for_one]]},
      type: :supervisor
    }

    supervisor = start_supervised!(supervisor_spec)

    old_pid = timeout_pid(supervisor)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), old_pid)
    monitor_ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^old_pid, :killed}, 1_000

    {:ok, pid} =
      eventually(fn ->
        case timeout_pid(supervisor) do
          ^old_pid -> nil
          child_pid when is_pid(child_pid) -> {:ok, child_pid}
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    assert :ok = FloorTimeout.arm(pid)

    assert eventually(fn -> Repo.get(FloorOwnership, ownership.id) == nil end)
  end

  test "automatic sweeps drain an expired backlog without waiting for normal cadence" do
    now = ~U[2026-08-01 12:00:00.000001Z]
    backlog_size = 205

    rows =
      for group_number <- 1..backlog_size do
        acquired_at = DateTime.add(now, -2_000, :millisecond)

        %{
          group_id: "expired-backlog-group-#{group_number}",
          user_id: "user-#{group_number}",
          priority: 1,
          acquired_at: acquired_at,
          inserted_at: acquired_at,
          updated_at: acquired_at
        }
      end

    assert {^backlog_size, nil} = Repo.insert_all(FloorOwnership, rows)
    parent = self()

    normal_interval_ms = 2_000

    pid =
      start_supervised!({
        FloorTimeout,
        [
          name: nil,
          timeout_ms: 1_000,
          interval_ms: normal_interval_ms,
          schedule?: false,
          clock: fn -> now end,
          notify: fn result -> send(parent, {:timeout_sweep, result}) end
        ]
      })

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    started_at = System.monotonic_time(:millisecond)
    assert :ok = FloorTimeout.arm(pid)

    assert_receive {:timeout_sweep, {:backlog, 100}}, 5_000
    first_follow_up_at = System.monotonic_time(:millisecond)
    assert first_follow_up_at - started_at < normal_interval_ms * 2

    assert_receive {:timeout_sweep, {:backlog, 100}}, 5_000
    second_follow_up_at = System.monotonic_time(:millisecond)
    assert second_follow_up_at - first_follow_up_at < div(normal_interval_ms, 2)

    assert_receive {:timeout_sweep, {:normal, 5}}, 5_000
    final_follow_up_at = System.monotonic_time(:millisecond)
    assert final_follow_up_at - second_follow_up_at < div(normal_interval_ms, 2)
    assert final_follow_up_at - started_at < normal_interval_ms * 3
    assert Repo.aggregate(FloorOwnership, :count) == 0
    assert timed_out_count() == backlog_size
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

  defp timed_out_count do
    FloorAuditEvent
    |> where([event], event.event_type == "timed_out")
    |> Repo.aggregate(:count)
  end

  defp timeout_pid(supervisor) do
    case Supervisor.which_children(supervisor) do
      [{FloorTimeout, pid, _type, _modules}] when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp eventually(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    eventually_until(fun, deadline)
  end

  defp eventually_until(fun, deadline) do
    case fun.() do
      value when value not in [false, nil] ->
        value

      _ ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          false
        else
          receive do
          after
            min(remaining, 10) -> eventually_until(fun, deadline)
          end
        end
    end
  end
end
