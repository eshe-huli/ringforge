defmodule Hub.RedirectController do
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  def to_dashboard(conn, _params) do
    redirect(conn, to: "/dashboard")
  end
end
