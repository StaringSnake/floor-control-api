defmodule FloorControl.FloorTimeout do
  use GenServer

  require Logger

  alias FloorControl.Floors

  @default_timeout_ms 30_000
  @minimum_timeout_seconds 1
  @maximum_sweep_interval_ms 60_000
  @minimum_interval_ms 100
  @backlog_follow_up_ms 1

  @spec parse_timeout_seconds!(String.t()) :: pos_integer()
  def parse_timeout_seconds!(value) do
    case Integer.parse(value) do
      {seconds, ""} ->
        if seconds >= @minimum_timeout_seconds and seconds <= max_timeout_seconds() do
          seconds * 1_000
        else
          invalid_timeout!(value)
        end

      _ ->
        invalid_timeout!(value)
    end
  end

  defp invalid_timeout!(value),
    do:
      raise(
        "FLOOR_TIMEOUT_SECONDS must be a positive integer within the supported DateTime range, got: #{value}"
      )

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec sweep(pid(), DateTime.t()) :: :ok
  def sweep(server, now), do: GenServer.call(server, {:sweep, now})

  @spec arm(pid()) :: :ok
  def arm(server), do: GenServer.call(server, :arm)

  @impl true
  def init(options) do
    timeout_ms = Keyword.get(options, :timeout_ms, configured_timeout_ms())
    clock = Keyword.get(options, :clock, &DateTime.utc_now/0)
    interval_ms = Keyword.get(options, :interval_ms, sweep_interval(timeout_ms))
    notify = Keyword.get(options, :notify)

    state = %{
      clock: clock,
      timeout_ms: timeout_ms,
      interval_ms: interval_ms,
      notify: notify,
      timer: nil
    }

    if Keyword.get(options, :schedule?, true),
      do: {:ok, schedule_timer(state, interval_ms)},
      else: {:ok, state}
  end

  @impl true
  def handle_info({:sweep, token}, %{timer: {_ref, token}} = state) do
    state = %{state | timer: nil}
    result = run_sweep(state)
    notify(state.notify, result)

    case result do
      {:backlog, _count} -> schedule_timer(state, @backlog_follow_up_ms)
      {:normal, _count} -> schedule_timer(state, state.interval_ms)
    end
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_info({:sweep, _stale_token}, state), do: {:noreply, state}

  @impl true
  def handle_call({:sweep, now}, _from, state) do
    run_sweep(%{state | clock: fn -> now end})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:arm, _from, state) do
    if state.timer do
      {:reply, :ok, state}
    else
      {:reply, :ok, schedule_timer(state, state.interval_ms)}
    end
  end

  defp run_sweep(%{clock: clock, timeout_ms: timeout_ms}) do
    case Floors.expire_expired(clock.(), timeout_ms) do
      {:ok, 0, false} ->
        {:normal, 0}

      {:ok, count, true} ->
        Logger.info("floor timeout sweep released #{count} ownerships; continuing backlog sweep")
        {:backlog, count}

      {:ok, count, false} ->
        if count > 0, do: Logger.info("floor timeout sweep released #{count} ownerships")
        {:normal, count}
    end
  rescue
    exception in [DBConnection.ConnectionError, Postgrex.Error] ->
      Logger.error(
        "floor timeout sweep could not access the database: #{Exception.message(exception)}"
      )

      {:normal, 0}
  end

  defp notify(notify, result) when is_function(notify, 1), do: notify.(result)
  defp notify(_notify, _result), do: :ok

  defp configured_timeout_ms do
    Application.get_env(:floor_control, :floor_timeout_ms, @default_timeout_ms)
  end

  defp sweep_interval(timeout_ms),
    do: timeout_ms |> div(2) |> max(@minimum_interval_ms) |> min(@maximum_sweep_interval_ms)

  defp max_timeout_seconds do
    DateTime.diff(DateTime.utc_now(), ~U[-9999-01-01 00:00:00Z], :second)
  end

  defp schedule_timer(state, interval_ms) do
    token = make_ref()
    timer_ref = Process.send_after(self(), {:sweep, token}, interval_ms)
    %{state | timer: {timer_ref, token}}
  end
end
