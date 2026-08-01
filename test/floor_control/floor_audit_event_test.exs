defmodule FloorControl.FloorAuditEventTest do
  use FloorControl.DataCase, async: false

  alias FloorControl.FloorAuditEvent

  @occurred_at ~U[2026-08-01 12:00:00.000000Z]

  test "migration creates the deterministic group and time audit index" do
    assert [[true]] =
             Ecto.Adapters.SQL.query!(
               Repo,
               """
               SELECT EXISTS (
                 SELECT 1
                 FROM pg_indexes
                 WHERE indexname = 'floor_audit_events_group_occurred_id_index'
               )
               """
             ).rows
  end

  test "audit changeset requires fields and defaults priority" do
    changeset =
      FloorAuditEvent.changeset(%FloorAuditEvent{}, %{
        group_id: "group-1",
        user_id: "user-1",
        event_type: "acquired",
        occurred_at: @occurred_at
      })

    assert changeset.valid?
    assert %FloorAuditEvent{priority: 1} = Ecto.Changeset.apply_changes(changeset)

    invalid = FloorAuditEvent.changeset(%FloorAuditEvent{}, %{})

    assert Enum.sort(invalid.errors |> Keyword.keys()) ==
             [:event_type, :group_id, :occurred_at, :user_id]
  end

  test "audit changeset accepts priority boundaries and rejects values outside them" do
    for priority <- [1, 10] do
      assert FloorAuditEvent.changeset(%FloorAuditEvent{}, %{
               group_id: "group-1",
               user_id: "user-1",
               event_type: "acquired",
               priority: priority,
               occurred_at: @occurred_at
             }).valid?
    end

    for priority <- [0, 11] do
      refute FloorAuditEvent.changeset(%FloorAuditEvent{}, %{
               group_id: "group-1",
               user_id: "user-1",
               event_type: "acquired",
               priority: priority,
               occurred_at: @occurred_at
             }).valid?
    end
  end

  test "database rejects an audit priority outside the allowed range" do
    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%FloorAuditEvent{
        group_id: "group-1",
        user_id: "user-1",
        event_type: "acquired",
        priority: 0,
        occurred_at: @occurred_at
      })
    end
  end

  test "audit events retain an explicit timestamp and id tie-breaker" do
    event_time = ~U[2026-08-01 12:00:00.000000Z]

    for user_id <- ["user-1", "user-2"] do
      assert {:ok, _event} =
               Repo.insert(
                 FloorAuditEvent.changeset(%FloorAuditEvent{}, %{
                   group_id: "group-1",
                   user_id: user_id,
                   event_type: "acquired",
                   priority: 1,
                   occurred_at: event_time
                 })
               )
    end

    assert [%{user_id: "user-1"}, %{user_id: "user-2"}] =
             FloorAuditEvent
             |> Ecto.Query.where([event], event.group_id == "group-1")
             |> Ecto.Query.order_by([event], asc: event.occurred_at, asc: event.id)
             |> Repo.all()
             |> Enum.map(&Map.take(&1, [:user_id]))
  end

  test "audit events cannot be updated" do
    insert_event()

    assert_raise Postgrex.Error, ~r/floor_audit_events are append-only/, fn ->
      Repo.update_all(FloorAuditEvent, set: [event_type: "released"])
    end
  end

  test "audit events cannot be deleted" do
    event = insert_event()

    assert_raise Postgrex.Error, ~r/floor_audit_events are append-only/, fn ->
      Repo.delete(event)
    end
  end

  test "audit events cannot be truncated" do
    insert_event()

    assert_raise Postgrex.Error, ~r/floor_audit_events are append-only/, fn ->
      Ecto.Adapters.SQL.query!(Repo, "TRUNCATE TABLE floor_audit_events")
    end
  end

  defp insert_event do
    Repo.insert!(
      FloorAuditEvent.changeset(%FloorAuditEvent{}, %{
        group_id: "group-1",
        user_id: "user-1",
        event_type: "acquired",
        occurred_at: @occurred_at
      })
    )
  end
end
