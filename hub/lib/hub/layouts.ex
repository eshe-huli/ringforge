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
        <title>RingForge — Agent Coordination Mesh</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <script>
          tailwind.config = {
            theme: {
              extend: {
                fontFamily: {
                  mono: ['JetBrains Mono', 'Fira Code', 'monospace'],
                  sans: ['JetBrains Mono', 'system-ui', 'sans-serif']
                },
                colors: {
                  'rf-bg': '#0a0a0f',
                  'rf-card': '#111119',
                  'rf-border': '#1a1a2e',
                  'rf-border-bright': '#252540',
                  'rf-accent': '#f59e0b',
                  'rf-accent-dim': '#92610b',
                  'rf-text': '#e2e8f0',
                  'rf-text-sec': '#94a3b8',
                  'rf-text-muted': '#475569',
                }
              }
            }
          }
        </script>
        <style>
          @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:ital,wght@0,300;0,400;0,500;0,600;0,700;1,400&display=swap');

          /* ── Animations ──────────────────────────── */
          @keyframes fadeIn {
            from { opacity: 0; transform: translateY(-6px); }
            to { opacity: 1; transform: translateY(0); }
          }
          .fade-in { animation: fadeIn 0.35s ease-out; }

          @keyframes fadeInUp {
            from { opacity: 0; transform: translateY(12px); }
            to { opacity: 1; transform: translateY(0); }
          }
          .fade-in-up { animation: fadeInUp 0.5s ease-out; }

          @keyframes pulse-dot {
            0%, 100% { box-shadow: 0 0 0 0 currentColor; opacity: 1; }
            50% { box-shadow: 0 0 6px 2px currentColor; opacity: 0.7; }
          }
          .pulse-dot { animation: pulse-dot 2s ease-in-out infinite; }

          @keyframes pulse-glow {
            0%, 100% { opacity: 0.6; }
            50% { opacity: 1; }
          }
          .pulse-glow { animation: pulse-glow 2.5s ease-in-out infinite; }

          @keyframes shimmer {
            0% { background-position: -200% center; }
            100% { background-position: 200% center; }
          }
          .shimmer {
            background: linear-gradient(90deg, transparent 30%, rgba(245,158,11,0.08) 50%, transparent 70%);
            background-size: 200% 100%;
            animation: shimmer 3s ease-in-out infinite;
          }

          @keyframes float-subtle {
            0%, 100% { transform: translateY(0); }
            50% { transform: translateY(-3px); }
          }
          .float-subtle { animation: float-subtle 4s ease-in-out infinite; }

          @keyframes borderGlow {
            0%, 100% { border-color: rgba(245,158,11,0.3); }
            50% { border-color: rgba(245,158,11,0.6); }
          }
          .border-glow { animation: borderGlow 2s ease-in-out infinite; }

          /* ── Background Grid ─────────────────────── */
          .bg-grid {
            background-image:
              radial-gradient(circle at 1px 1px, rgba(255,255,255,0.03) 1px, transparent 0);
            background-size: 32px 32px;
          }

          .bg-radial-glow {
            background: radial-gradient(ellipse at 50% 0%, rgba(245,158,11,0.05) 0%, transparent 60%);
          }

          /* ── Glass Card ──────────────────────────── */
          .glass-card {
            background: rgba(17, 17, 25, 0.7);
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            border: 1px solid rgba(26, 26, 46, 0.8);
          }
          .glass-card:hover {
            background: rgba(17, 17, 25, 0.85);
            border-color: rgba(37, 37, 64, 0.9);
          }

          /* ── Scrollbar ───────────────────────────── */
          ::-webkit-scrollbar { width: 5px; }
          ::-webkit-scrollbar-track { background: transparent; }
          ::-webkit-scrollbar-thumb { background: #252540; border-radius: 4px; }
          ::-webkit-scrollbar-thumb:hover { background: #3a3a5c; }
          * { scrollbar-width: thin; scrollbar-color: #252540 transparent; }

          /* ── Bar glow ────────────────────────────── */
          .bar-glow-green {
            box-shadow: 0 0 8px rgba(34, 197, 94, 0.3);
          }
          .bar-glow-yellow {
            box-shadow: 0 0 8px rgba(234, 179, 8, 0.3);
          }
          .bar-glow-red {
            box-shadow: 0 0 8px rgba(239, 68, 68, 0.3);
          }

          /* ── Activity accent bar ─────────────────── */
          .accent-bar {
            position: relative;
          }
          .accent-bar::before {
            content: '';
            position: absolute;
            left: 0;
            top: 4px;
            bottom: 4px;
            width: 3px;
            border-radius: 3px;
            background: currentColor;
            opacity: 0.6;
          }

          /* ── Focus glow ──────────────────────────── */
          .focus-glow:focus {
            box-shadow: 0 0 0 2px rgba(245, 158, 11, 0.15), 0 0 12px rgba(245, 158, 11, 0.08);
          }

          /* ── Toast ───────────────────────────────── */
          .toast-enter {
            animation: fadeIn 0.3s ease-out, fadeOut 0.3s ease-in 3s forwards;
          }
          @keyframes fadeOut {
            to { opacity: 0; transform: translateY(-4px); }
          }

          /* ── Transitions ─────────────────────────── */
          .transition-smooth {
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
          }
        </style>
      </head>
      <body class="h-full bg-rf-bg text-rf-text font-mono antialiased bg-grid">
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
