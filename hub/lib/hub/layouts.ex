defmodule Hub.Layouts do
  @moduledoc """
  Root and app layouts for LiveView pages.
  """
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>RingForge Dashboard</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <script>
          tailwind.config = {
            theme: {
              extend: {
                fontFamily: {
                  mono: ['JetBrains Mono', 'Fira Code', 'monospace']
                }
              }
            }
          }
        </script>
        <style>
          @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;700&display=swap');

          @keyframes fadeIn {
            from { opacity: 0; transform: translateY(-4px); }
            to { opacity: 1; transform: translateY(0); }
          }
          .fade-in { animation: fadeIn 0.3s ease-out; }

          @keyframes pulse-dot {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
          }
          .pulse-dot { animation: pulse-dot 2s ease-in-out infinite; }

          ::-webkit-scrollbar { width: 6px; }
          ::-webkit-scrollbar-track { background: #1a1a2e; }
          ::-webkit-scrollbar-thumb { background: #333; border-radius: 3px; }
          ::-webkit-scrollbar-thumb:hover { background: #555; }
        </style>
      </head>
      <body class="h-full bg-gray-950 text-gray-100 font-mono antialiased">
        <%= @inner_content %>
        <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7.21/priv/static/phoenix.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@0.20.17/priv/static/phoenix_live_view.min.js"></script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: { _csrf_token: csrfToken }
          })
          liveSocket.connect()
          window.liveSocket = liveSocket
        </script>
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <%= @inner_content %>
    """
  end
end
