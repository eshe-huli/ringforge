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
    websocket: [
      timeout: 45_000,
      check_origin: false,
      connect_info: [:peer_data, :x_headers],
      serializer: [{Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}]
    ],
    longpoll: false

  # LiveView WebSocket transport
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      check_origin: false,
      connect_info: [session: @session_options]
    ]

  plug Plug.Session, @session_options

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["application/json"],
    json_decoder: Jason

  plug Plug.Head
  plug Hub.Router
end
