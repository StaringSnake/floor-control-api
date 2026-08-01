defmodule FloorControl.Repo.Migrations.CreateFloorOwnershipAndAuditEvents do
  use Ecto.Migration

  def change do
    create table(:floor_ownerships) do
      add :group_id, :string, null: false
      add :user_id, :string, null: false
      add :priority, :integer, null: false, default: 1
      add :acquired_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:floor_ownerships, [:group_id],
             name: :floor_ownerships_group_id_unique_index
           )

    create constraint(:floor_ownerships, :floor_ownerships_priority_range,
             check: "priority BETWEEN 1 AND 10"
           )

    create table(:floor_audit_events) do
      add :group_id, :string, null: false
      add :user_id, :string, null: false
      add :event_type, :string, null: false
      add :priority, :integer, null: false, default: 1
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:floor_audit_events, [:group_id, :occurred_at, :id],
             name: :floor_audit_events_group_occurred_id_index
           )

    create constraint(:floor_audit_events, :floor_audit_events_priority_range,
             check: "priority BETWEEN 1 AND 10"
           )

    execute(
      """
      CREATE FUNCTION floor_control_reject_audit_mutation() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'floor_audit_events are append-only';
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS floor_control_reject_audit_mutation();"
    )

    execute(
      """
      CREATE TRIGGER floor_audit_events_append_only
      BEFORE UPDATE OR DELETE ON floor_audit_events
      FOR EACH ROW EXECUTE FUNCTION floor_control_reject_audit_mutation();
      """,
      "DROP TRIGGER IF EXISTS floor_audit_events_append_only ON floor_audit_events;"
    )

    execute(
      """
      CREATE TRIGGER floor_audit_events_truncate_append_only
      BEFORE TRUNCATE ON floor_audit_events
      FOR EACH STATEMENT EXECUTE FUNCTION floor_control_reject_audit_mutation();
      """,
      "DROP TRIGGER IF EXISTS floor_audit_events_truncate_append_only ON floor_audit_events;"
    )
  end
end
