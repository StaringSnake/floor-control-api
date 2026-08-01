defmodule FloorControl.FloorAuditEvent do
  use Ecto.Schema

  import Ecto.Changeset

  @priority_check :floor_audit_events_priority_range
  @counterparty_provenance_check :floor_audit_events_counterparty_provenance
  @event_types ~w(acquired released timed_out preempted)

  schema "floor_audit_events" do
    field :group_id, :string
    field :user_id, :string
    field :event_type, :string
    field :priority, :integer, default: 1
    field :counterparty_user_id, :string
    field :counterparty_priority, :integer
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :group_id,
      :user_id,
      :event_type,
      :priority,
      :counterparty_user_id,
      :counterparty_priority,
      :occurred_at
    ])
    |> validate_required([:group_id, :user_id, :event_type, :priority, :occurred_at])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_number(:priority, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> validate_counterparty_provenance()
    |> validate_number(:counterparty_priority,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 10
    )
    |> check_constraint(:priority, name: @priority_check)
    |> check_constraint(:counterparty_user_id, name: @counterparty_provenance_check)
  end

  defp validate_counterparty_provenance(changeset) do
    event_type = get_field(changeset, :event_type)
    user_id = get_field(changeset, :counterparty_user_id)
    priority = get_field(changeset, :counterparty_priority)

    cond do
      event_type == "preempted" and is_nil(user_id) ->
        add_error(changeset, :counterparty_user_id, "is required for preempted events")

      is_nil(user_id) != is_nil(priority) ->
        add_error(changeset, :counterparty_user_id, "must be provided with counterparty priority")

      not is_nil(user_id) and event_type not in ["preempted", "acquired"] ->
        add_error(changeset, :counterparty_user_id, "is only valid for preemption events")

      not is_nil(user_id) and user_id == get_field(changeset, :user_id) ->
        add_error(changeset, :counterparty_user_id, "must differ from user id")

      true ->
        changeset
    end
  end
end
