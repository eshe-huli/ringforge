defmodule Hub.Endpoint do
  use Phoenix.Endpoint, otp_app: :hub

  @session_options [
    store: :cookie,
    key: "_hub_key",
    signing_salt: "ringforge_lv",
    same_site: "Lax"
  ]

  # Agent WebSocket transport
  socket "/ws", Hub.Socket,
    websocket: [timeout: 45_000],
    longpoll: false

  # LiveView WebSocket transport
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Session, @session_options

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["application/json"],
    json_decoder: Jason

  plug Plug.Head
  plug Hub.Router
end
