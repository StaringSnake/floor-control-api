defmodule FloorControl.Floors do
  import Ecto.Query

  alias FloorControl.{FloorAuditEvent, FloorOwnership, Repo}

  @expiration_batch_size 100

  @type result ::
          {:ok, FloorOwnership.t()}
          | {:error, :conflict, FloorOwnership.t()}
          | {:error, :contention}
          | {:error, :forbidden}
          | {:error, {:validation, String.t()}}

  @spec obtain(term(), term()) :: result()
  def obtain(group_id, attrs) do
    with {:ok, group_id} <- normalize_identifier(group_id, "groupId"),
         {:ok, attrs} <- validate_obtain_attrs(attrs),
         {:ok, user_id} <- normalize_identifier(attrs.user_id, "userId") do
      do_obtain(group_id, user_id, attrs.priority)
    end
  end

  @spec release(term(), term()) ::
          {:ok, FloorOwnership.t()}
          | {:error, :forbidden}
          | {:error, {:validation, String.t()}}
  def release(group_id, user_id) do
    with {:ok, group_id} <- normalize_identifier(group_id, "groupId"),
         {:ok, user_id} <- normalize_identifier(user_id, "userId") do
      Repo.transaction(fn ->
        case Repo.one(
               from ownership in FloorOwnership,
                 where: ownership.group_id == ^group_id,
                 lock: "FOR UPDATE"
             ) do
          %FloorOwnership{user_id: ^user_id} = ownership ->
            insert_audit!(ownership, "released")
            Repo.delete!(ownership)
            ownership

          _ownership ->
            Repo.rollback(:forbidden)
        end
      end)
      |> normalize_transaction_result()
    end
  end

  @spec current_holder(term()) ::
          {:ok, FloorOwnership.t() | nil}
          | {:error, {:validation, String.t()}}
  def current_holder(group_id) do
    with {:ok, group_id} <- normalize_identifier(group_id, "groupId") do
      {:ok, Repo.get_by(FloorOwnership, group_id: group_id)}
    end
  end

  @doc "Releases expired ownerships and reports whether the bounded batch was full."
  @spec expire_expired(DateTime.t(), pos_integer()) ::
          {:ok, non_neg_integer(), boolean()}
  def expire_expired(now, timeout_ms) do
    cutoff = DateTime.add(now, -timeout_ms, :millisecond)

    Repo.transaction(fn ->
      expired_count =
        expired_ownerships(cutoff)
        |> Enum.count(&expire_ownership(&1, cutoff, now))

      {expired_count, expired_count == @expiration_batch_size}
    end)
    |> case do
      {:ok, {count, full_batch?}} -> {:ok, count, full_batch?}
    end
  end

  defp expired_ownerships(cutoff) do
    # The candidates are locked by this transaction, so obtain/release cannot
    # replace or delete them until the audit and ownership delete commit.
    Repo.all(
      from ownership in FloorOwnership,
        where: ownership.acquired_at <= ^cutoff,
        order_by: [asc: ownership.acquired_at, asc: ownership.id],
        limit: ^@expiration_batch_size,
        lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  defp expire_ownership(ownership, cutoff, now) do
    if DateTime.compare(ownership.acquired_at, cutoff) in [:lt, :eq] do
      insert_audit!(ownership, "timed_out", now)
      Repo.delete!(ownership)
      true
    else
      false
    end
  end

  defp do_obtain(group_id, user_id, priority) do
    transaction_result =
      Repo.transaction(fn ->
        case Repo.one(
               from ownership in FloorOwnership,
                 where: ownership.group_id == ^group_id,
                 lock: "FOR UPDATE"
             ) do
          nil ->
            case insert_ownership(group_id, user_id, priority) do
              {:ok, ownership} ->
                insert_audit!(ownership, "acquired")
                ownership

              {:error, changeset} ->
                Repo.rollback(changeset)
            end

          %FloorOwnership{user_id: ^user_id} = ownership ->
            ownership

          %FloorOwnership{priority: current_priority} = ownership
          when priority > current_priority ->
            acquired_at = DateTime.utc_now()
            previous_user_id = ownership.user_id

            incoming = %{
              group_id: group_id,
              user_id: user_id,
              priority: priority,
              acquired_at: acquired_at
            }

            ownership =
              ownership
              |> FloorOwnership.changeset(incoming)
              |> Repo.update!()

            insert_audit!(
              %FloorAuditEvent{
                group_id: group_id,
                user_id: previous_user_id,
                priority: current_priority
              },
              "preempted",
              acquired_at,
              user_id,
              priority
            )

            insert_audit!(ownership, "acquired", acquired_at, previous_user_id, current_priority)
            ownership

          ownership ->
            Repo.rollback({:conflict, ownership})
        end
      end)

    case transaction_result do
      {:ok, ownership} ->
        {:ok, ownership}

      {:error, {:conflict, ownership}} ->
        {:error, :conflict, ownership}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_group_conflict?(changeset) do
          resolve_concurrent_obtain(group_id, user_id)
        else
          {:error, {:validation, "request is invalid"}}
        end
    end
  end

  defp resolve_concurrent_obtain(group_id, user_id) do
    case Repo.get_by(FloorOwnership, group_id: group_id) do
      %FloorOwnership{user_id: ^user_id} = ownership -> {:ok, ownership}
      %FloorOwnership{} = ownership -> {:error, :conflict, ownership}
      nil -> {:error, :contention}
    end
  end

  defp insert_ownership(group_id, user_id, priority) do
    %FloorOwnership{}
    |> FloorOwnership.changeset(%{
      group_id: group_id,
      user_id: user_id,
      priority: priority,
      acquired_at: DateTime.utc_now()
    })
    |> Repo.insert()
  end

  defp insert_audit!(
         ownership,
         event_type,
         occurred_at \\ DateTime.utc_now(),
         counterparty_user_id \\ nil,
         counterparty_priority \\ nil
       ) do
    %FloorAuditEvent{}
    |> FloorAuditEvent.changeset(%{
      group_id: ownership.group_id,
      user_id: ownership.user_id,
      event_type: event_type,
      priority: ownership.priority,
      counterparty_user_id: counterparty_user_id,
      counterparty_priority: counterparty_priority,
      occurred_at: occurred_at
    })
    |> Repo.insert!()
  end

  defp validate_obtain_attrs(attrs) when is_map(attrs) do
    priority = Map.get(attrs, :priority, Map.get(attrs, "priority", 1))
    user_id = Map.get(attrs, :user_id, Map.get(attrs, "userId"))

    cond do
      not is_integer(priority) or priority < 1 or priority > 10 ->
        {:error, {:validation, "priority must be an integer between 1 and 10"}}

      true ->
        {:ok, %{user_id: user_id, priority: priority}}
    end
  end

  defp validate_obtain_attrs(_attrs),
    do: {:error, {:validation, "request body must be an object"}}

  defp normalize_identifier(value, field) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:error, {:validation, "#{field} must be a non-empty string"}}

      value ->
        if String.length(value) > 255 do
          {:error, {:validation, "#{field} must be at most 255 characters"}}
        else
          {:ok, value}
        end
    end
  end

  defp normalize_identifier(_value, field),
    do: {:error, {:validation, "#{field} must be a non-empty string"}}

  defp normalize_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp unique_group_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {:group_id, {_message, metadata}} -> metadata[:constraint] == :unique
      _ -> false
    end)
  end
end
