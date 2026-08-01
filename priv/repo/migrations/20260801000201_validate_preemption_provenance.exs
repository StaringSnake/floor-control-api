defmodule FloorControl.Repo.Migrations.ValidatePreemptionProvenance do
  use Ecto.Migration

  @disable_ddl_transaction true

  def up do
    execute("""
    ALTER TABLE floor_audit_events
    VALIDATE CONSTRAINT floor_audit_events_counterparty_provenance
    """)
  end

  def down do
    :ok
  end
end
