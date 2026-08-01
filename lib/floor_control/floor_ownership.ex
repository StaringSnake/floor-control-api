defmodule FloorControl.FloorOwnership do
  use Ecto.Schema

  import Ecto.Changeset

  @group_unique_index :floor_ownerships_group_id_unique_index
  @priority_check :floor_ownerships_priority_range

  schema "floor_ownerships" do
    field :group_id, :string
    field :user_id, :string
    field :priority, :integer, default: 1
    field :acquired_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(ownership, attrs) do
    ownership
    |> cast(attrs, [:group_id, :user_id, :priority, :acquired_at])
    |> validate_required([:group_id, :user_id, :priority, :acquired_at])
    |> validate_number(:priority, greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> unique_constraint(:group_id, name: @group_unique_index)
    |> check_constraint(:priority, name: @priority_check)
  end
end
