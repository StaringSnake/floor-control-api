defmodule FloorControlWeb.FloorController do
  use FloorControlWeb, :controller

  alias FloorControl.Floors

  def obtain(conn, params) do
    case Floors.obtain(params["groupId"], params) do
      {:ok, ownership} ->
        json(conn, %{
          message: "Floor obtained by #{ownership.user_id} for group #{ownership.group_id}"
        })

      {:error, :conflict, ownership} ->
        error(
          conn,
          :conflict,
          "Floor is currently held by #{ownership.user_id} for group #{ownership.group_id}"
        )

      {:error, :contention} ->
        error(
          conn,
          :conflict,
          "Floor request could not be completed due to concurrent contention"
        )

      {:error, {:validation, message}} ->
        error(conn, :bad_request, message)
    end
  end

  def current_holder(conn, %{"groupId" => group_id}) do
    case Floors.current_holder(group_id) do
      {:ok, ownership} ->
        json(conn, %{holder: holder_response(ownership)})

      {:error, {:validation, message}} ->
        error(conn, :bad_request, message)
    end
  end

  def history(conn, %{"groupId" => group_id} = params) do
    case Floors.history(group_id, params) do
      {:ok, events, next_page_token} ->
        json(conn, %{
          events: Enum.map(events, &history_event_response/1),
          nextPageToken: next_page_token
        })

      {:error, {:validation, message}} ->
        error(conn, :bad_request, message)
    end
  end

  def release(conn, %{"groupId" => group_id, "userId" => user_id}) do
    case Floors.release(group_id, user_id) do
      {:ok, ownership} ->
        json(conn, %{
          message: "Floor released by #{ownership.user_id} for group #{ownership.group_id}"
        })

      {:error, :forbidden} ->
        error(conn, :forbidden, "User #{user_id} does not hold the floor for group #{group_id}")

      {:error, {:validation, message}} ->
        error(conn, :bad_request, message)
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{message: message})
  end

  defp holder_response(nil), do: nil

  defp holder_response(ownership) do
    %{
      userId: ownership.user_id,
      priority: ownership.priority,
      acquiredAt: ownership.acquired_at
    }
  end

  defp history_event_response(event) do
    %{
      eventId: event.id,
      groupId: event.group_id,
      userId: event.user_id,
      transition: event.event_type,
      priority: event.priority,
      counterparty: counterparty_response(event),
      occurredAt: event.occurred_at,
      recordedAt: event.inserted_at
    }
  end

  defp counterparty_response(%{counterparty_user_id: nil, counterparty_priority: nil}), do: nil

  defp counterparty_response(event) do
    %{userId: event.counterparty_user_id, priority: event.counterparty_priority}
  end
end
