defmodule FloorControlWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint FloorControlWeb.Endpoint
      use Phoenix.ConnTest
      import Plug.Conn
      import FloorControlWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
