defmodule FloorControl.Repo.Migrations.AddPreemptionProvenanceToAuditEvents do
  use Ecto.Migration

  def up do
    alter table(:floor_audit_events) do
      add :counterparty_user_id, :string
      add :counterparty_priority, :integer
    end

    execute("""
    ALTER TABLE floor_audit_events
    ADD CONSTRAINT floor_audit_events_counterparty_provenance
    CHECK (
      (
        event_type IN ('acquired', 'released', 'timed_out', 'preempted')
        AND
        (counterparty_user_id IS NULL AND counterparty_priority IS NULL)
        OR (
          event_type IN ('acquired', 'preempted')
          AND counterparty_user_id IS NOT NULL
          AND counterparty_priority BETWEEN 1 AND 10
          AND counterparty_user_id <> user_id
        )
      )
      AND (
        event_type <> 'preempted'
        OR (counterparty_user_id IS NOT NULL AND counterparty_priority IS NOT NULL)
      )
    ) NOT VALID
    """)
  end

  def down do
    execute("""
    ALTER TABLE floor_audit_events
    DROP CONSTRAINT floor_audit_events_counterparty_provenance
    """)

    alter table(:floor_audit_events) do
      remove :counterparty_priority
      remove :counterparty_user_id
    end
  end
end
