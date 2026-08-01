defmodule FloorControlWeb.ErrorJSON do
  def render(template, _assigns) do
    %{message: Phoenix.Controller.status_message_from_template(template)}
  end
end
