defmodule FloorControl.FloorOwnershipTest do
  use FloorControl.DataCase, async: false

  alias FloorControl.FloorOwnership

  @acquired_at ~U[2026-08-01 12:00:00.000000Z]

  test "migration creates the ownership table and group uniqueness index" do
    assert [["floor_ownerships"]] =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT relname FROM pg_class WHERE oid = 'floor_ownerships'::regclass"
             ).rows

    assert [[true]] =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT EXISTS (
                 SELECT 1
                 FROM pg_indexes
                 WHERE indexname = 'floor_ownerships_group_id_unique_index'
               )
               """
             ).rows

    assert [[true]] =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT EXISTS (
                 SELECT 1
                 FROM pg_constraint
                 WHERE conname = 'floor_ownerships_priority_range'
               )
               """
             ).rows
  end

  test "ownership changeset requires fields and defaults priority" do
    changeset =
      FloorOwnership.changeset(%FloorOwnership{}, %{
        group_id: "group-1",
        user_id: "user-1",
        acquired_at: @acquired_at
      })

    assert changeset.valid?
    assert %FloorOwnership{priority: 1} = Ecto.Changeset.apply_changes(changeset)

    invalid = FloorOwnership.changeset(%FloorOwnership{}, %{})
    assert Enum.sort(invalid.errors |> Keyword.keys()) == [:acquired_at, :group_id, :user_id]
  end

  test "ownership changeset accepts priority boundaries and rejects values outside them" do
    for priority <- [1, 10] do
      assert FloorOwnership.changeset(%FloorOwnership{}, %{
               group_id: "group-1",
               user_id: "user-1",
               priority: priority,
               acquired_at: @acquired_at
             }).valid?
    end

    for priority <- [0, 11] do
      refute FloorOwnership.changeset(%FloorOwnership{}, %{
               group_id: "group-1",
               user_id: "user-1",
               priority: priority,
               acquired_at: @acquired_at
             }).valid?
    end
  end

  test "database rejects an ownership priority outside the allowed range" do
    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%FloorOwnership{
        group_id: "group-1",
        user_id: "user-1",
        priority: 0,
        acquired_at: @acquired_at
      })
    end
  end

  test "database rejects concurrent ownership rows for the same group" do
    attrs = fn user_id ->
      %{
        group_id: "group-1",
        user_id: user_id,
        priority: 1,
        acquired_at: ~U[2026-08-01 12:00:00.000000Z]
      }
    end

    tasks =
      for user_id <- ["user-1", "user-2"] do
        parent = self()

        task =
          Task.async(fn ->
            send(parent, {:ownership_attempt_ready, self()})

            receive do
              :start -> Repo.insert(FloorOwnership.changeset(%FloorOwnership{}, attrs.(user_id)))
            end
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
        task
      end

    ready_pids =
      for _task <- tasks do
        receive do
          {:ownership_attempt_ready, pid} -> pid
        end
      end

    assert Enum.sort(ready_pids) == Enum.sort(Enum.map(tasks, & &1.pid))

    Enum.each(tasks, &send(&1.pid, :start))
    results = Enum.map(tasks, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, fn
             {:error, changeset} -> not changeset.valid?
             _ -> false
           end) == 1

    assert Repo.aggregate(FloorOwnership, :count) == 1
  end
end
