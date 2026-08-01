defmodule FloorControl.Health do
  @moduledoc false

  @spec database_status() :: :ok | :unavailable
  def database_status do
    database_status(Application.get_env(:floor_control, :health_repo, FloorControl.Repo))
  end

  @spec database_status(module()) :: :ok | :unavailable
  def database_status(repo) do
    case repo.query("SELECT 1", [], timeout: 1_000, pool_timeout: 1_000) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :unavailable
    end
  rescue
    DBConnection.ConnectionError -> :unavailable
  end
end
