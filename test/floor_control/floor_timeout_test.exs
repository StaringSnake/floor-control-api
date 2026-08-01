defmodule FloorControl.FloorTimeoutTest do
  use ExUnit.Case, async: true

  alias FloorControl.FloorTimeout

  test "uses a 30 second default timeout" do
    assert Application.get_env(:floor_control, :floor_timeout_ms) == 30_000
  end

  test "rejects invalid timeout configuration" do
    assert_raise RuntimeError, ~r/FLOOR_TIMEOUT_SECONDS must be a positive integer/, fn ->
      FloorTimeout.parse_timeout_seconds!("0")
    end

    assert_raise RuntimeError, ~r/FLOOR_TIMEOUT_SECONDS must be a positive integer/, fn ->
      FloorTimeout.parse_timeout_seconds!("30seconds")
    end

    assert_raise RuntimeError, ~r/FLOOR_TIMEOUT_SECONDS must be a positive integer/, fn ->
      FloorTimeout.parse_timeout_seconds!("999999999999999999")
    end
  end
end
