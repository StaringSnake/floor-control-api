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
end
