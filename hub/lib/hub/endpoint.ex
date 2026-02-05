defmodule Hub.Endpoint do
  use Phoenix.Endpoint, otp_app: :hub

  socket "/ws", Hub.Socket,
    websocket: [timeout: 45_000],
    longpoll: false

  plug Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason

  plug Plug.Head
  plug Hub.Router
end
