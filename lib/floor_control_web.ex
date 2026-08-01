defmodule FloorControlWeb do
  def controller do
    quote do
      use Phoenix.Controller, namespace: FloorControlWeb, formats: [:json]
      import Plug.Conn
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Plug.Conn
      import Phoenix.Controller
    end
  end

  defmacro __using__(which) when which in [:controller, :router], do: apply(__MODULE__, which, [])
end
