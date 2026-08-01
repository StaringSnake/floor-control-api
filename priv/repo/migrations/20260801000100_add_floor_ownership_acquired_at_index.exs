defmodule FloorControl.Repo.Migrations.AddFloorOwnershipAcquiredAtIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create index(:floor_ownerships, [:acquired_at, :id],
             name: :floor_ownerships_acquired_at_index,
             concurrently: true
           )
  end

  def down do
    drop index(:floor_ownerships, [:acquired_at, :id],
           name: :floor_ownerships_acquired_at_index,
           concurrently: true
         )
  end
end
