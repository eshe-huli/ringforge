defmodule Hub.Endpoint do
  use Phoenix.Endpoint, otp_app: :hub

  @session_options [
    store: :cookie,
    key: "_hub_key",
    signing_salt: "ringforge_lv",
    same_site: "Lax",
    secure: true,
    http_only: true,
    max_age: 86_400
  ]

  # Agent WebSocket transport
  # check_origin: false is acceptable here — agents connect via API key auth,
  # not browser sessions, so CSRF via origin isn't a risk vector.
  socket "/ws", Hub.Socket,
    websocket: [
      timeout: 45_000,
      check_origin: false,
      connect_info: [:peer_data, :x_headers],
      serializer: [{Phoenix.Socket.V2.JSONSerializer, "~> 2.0.0"}]
    ],
    longpoll: false

  # LiveView WebSocket transport — restrict to known origins
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [
      check_origin: ["https://ringforge.wejoona.com", "http://localhost:4000"],
      connect_info: [session: @session_options]
    ]

  plug Plug.Session, @session_options

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["application/json"],
    json_decoder: Jason,
    length: 1_000_000

  plug Plug.Head
  plug Hub.Router
end
