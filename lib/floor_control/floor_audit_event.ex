defmodule FloorControl.FloorAuditEvent do
  use Ecto.Schema

  import Ecto.Changeset

  @priority_check :floor_audit_events_priority_range

  schema "floor_audit_events" do
    field :group_id, :string
    field :user_id, :string
    field :event_type, :string
    field :priority, :integer, default: 1
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:group_id, :user_id, :event_type, :priority, :occurred_at])
    |> validate_required([:group_id, :user_id, :event_type, :priority, :occurred_at])
    |> validate_number(:priority, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> check_constraint(:priority, name: @priority_check)
  end
end
