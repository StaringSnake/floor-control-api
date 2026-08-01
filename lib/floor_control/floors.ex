defmodule FloorControl.Floors do
  import Ecto.Query

  alias FloorControl.{FloorAuditEvent, FloorOwnership, Repo}

  @expiration_batch_size 100
  @history_default_page_size 50
  @history_max_page_size 100
  @max_page_token_bytes 2_048
  @max_postgres_bigint 9_223_372_036_854_775_807

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

  @spec history(term(), map()) ::
          {:ok, [FloorAuditEvent.t()], String.t() | nil}
          | {:error, {:validation, String.t()}}
  def history(group_id, params) when is_map(params) do
    with {:ok, group_id} <- normalize_identifier(group_id, "groupId"),
         {:ok, page_size} <- validate_page_size(Map.get(params, "pageSize")),
         {:ok, page_token} <- decode_page_token(Map.get(params, "pageToken")),
         :ok <- validate_page_token_group(page_token, group_id),
         {:ok, snapshot} <- history_snapshot(page_token) do
      events = query_history(group_id, page_size, snapshot, page_token)
      {events, has_next_page?} = split_history_page(events, page_size)

      next_page_token =
        if has_next_page? do
          encode_page_token(List.last(events), snapshot.high_water_event_id, group_id)
        end

      {:ok, events, next_page_token}
    end
  end

  def history(_group_id, _params),
    do: {:error, {:validation, "query parameters must be an object"}}

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

  defp query_history(group_id, page_size, %{high_water_event_id: high_water_event_id}, nil) do
    from(event in FloorAuditEvent,
      where: event.group_id == ^group_id and event.id <= ^high_water_event_id,
      order_by: [asc: event.occurred_at, asc: event.id],
      limit: ^(page_size + 1)
    )
    |> Repo.all()
  end

  defp query_history(
         group_id,
         page_size,
         %{high_water_event_id: high_water_event_id},
         %{occurred_at: occurred_at, id: id}
       ) do
    where(
      from(event in FloorAuditEvent,
        where: event.group_id == ^group_id and event.id <= ^high_water_event_id,
        order_by: [asc: event.occurred_at, asc: event.id],
        limit: ^(page_size + 1)
      ),
      [event],
      fragment("(?, ?) > (?, ?)", event.occurred_at, event.id, ^occurred_at, ^id)
    )
    |> Repo.all()
  end

  defp split_history_page(events, page_size) do
    case Enum.split(events, page_size) do
      {page, [_extra]} -> {page, true}
      {page, []} -> {page, false}
    end
  end

  defp validate_page_size(nil), do: {:ok, @history_default_page_size}

  defp validate_page_size(page_size) when is_binary(page_size) do
    case Integer.parse(page_size) do
      {value, ""} when value in 1..@history_max_page_size -> {:ok, value}
      _ -> {:error, {:validation, "pageSize must be an integer between 1 and 100"}}
    end
  end

  defp validate_page_size(_page_size),
    do: {:error, {:validation, "pageSize must be an integer between 1 and 100"}}

  defp encode_page_token(
         %FloorAuditEvent{occurred_at: occurred_at, id: id},
         high_water_event_id,
         group_id
       ) do
    %{
      occurredAt: DateTime.to_iso8601(occurred_at),
      id: id,
      highWaterEventId: high_water_event_id,
      groupId: group_id
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp history_snapshot(nil) do
    {:ok,
     %{
       high_water_event_id:
         Repo.one(from event in FloorAuditEvent, select: coalesce(max(event.id), 0))
     }}
  end

  defp history_snapshot(snapshot), do: {:ok, snapshot}

  defp decode_page_token(nil), do: {:ok, nil}

  defp decode_page_token(token)
       when is_binary(token) and byte_size(token) <= @max_page_token_bytes do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false),
         {:ok, payload} <- Jason.decode(decoded),
         {:ok, snapshot} <- decode_token_payload(payload) do
      {:ok, snapshot}
    else
      _ -> {:error, {:validation, "pageToken is invalid"}}
    end
  end

  defp decode_page_token(_token), do: {:error, {:validation, "pageToken is invalid"}}

  defp validate_page_token_group(nil, _group_id), do: :ok

  defp validate_page_token_group(%{group_id: token_group_id}, group_id)
       when token_group_id == group_id,
       do: :ok

  defp validate_page_token_group(_page_token, _group_id),
    do: {:error, {:validation, "pageToken is invalid"}}

  defp decode_token_payload(
         %{
           "occurredAt" => occurred_at,
           "id" => id,
           "highWaterEventId" => high_water_event_id,
           "groupId" => group_id
         } = payload
       )
       when map_size(payload) == 4 do
    with {:ok, group_id} <- decode_token_group(group_id),
         {:ok, occurred_at} <- decode_token_timestamp(occurred_at),
         {:ok, id} <- decode_token_integer(id, 1),
         {:ok, high_water_event_id} <- decode_token_integer(high_water_event_id, 0),
         true <- id <= high_water_event_id do
      {:ok,
       %{
         group_id: group_id,
         occurred_at: occurred_at,
         id: id,
         high_water_event_id: high_water_event_id
       }}
    else
      _ -> :error
    end
  end

  defp decode_token_payload(_payload), do: :error

  defp decode_token_group(value) when is_binary(value) do
    case normalize_identifier(value, "groupId") do
      {:ok, ^value} -> {:ok, value}
      _ -> :error
    end
  end

  defp decode_token_group(_value), do: :error

  defp decode_token_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, occurred_at, 0} -> {:ok, occurred_at}
      _ -> :error
    end
  end

  defp decode_token_timestamp(_value), do: :error

  defp decode_token_integer(value, minimum)
       when is_integer(value) and value >= minimum and value <= @max_postgres_bigint,
       do: {:ok, value}

  defp decode_token_integer(_value, _minimum), do: :error

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
