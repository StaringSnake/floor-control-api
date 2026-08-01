defmodule FloorControl.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FloorControl.Repo,
      {Phoenix.PubSub, name: FloorControl.PubSub},
      {FloorControl.FloorTimeout,
       [schedule?: Application.get_env(:floor_control, :floor_timeout_schedule, true)]},
      FloorControlWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: FloorControl.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    FloorControlWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
