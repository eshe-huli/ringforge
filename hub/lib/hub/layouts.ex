defmodule Hub.Layouts do
  @moduledoc """
  Root and app layouts for LiveView pages.
  Mirrors the Flow Designer design system: zinc color scale,
  clean borders, fast transitions, JetBrains Mono.
  """
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
        <title>RingForge — Agent Coordination Mesh</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <script>
          tailwind.config = {
            darkMode: 'class',
            theme: {
              extend: {
                fontFamily: {
                  mono: ['JetBrains Mono', 'Fira Code', 'ui-monospace', 'monospace'],
                  sans: ['JetBrains Mono', 'system-ui', 'sans-serif']
                }
              }
            }
          }
        </script>
        <style>
          @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:ital,wght@0,300;0,400;0,500;0,600;0,700;1,400&display=swap');

          :root {
            --background: #09090b;
            --foreground: #fafafa;
            --surface: #18181b;
            --surface-hover: #27272a;
            --border: #27272a;
            --muted: #a1a1aa;
            --accent: #f59e0b;
            --accent-dim: #b45309;
          }

          body {
            background: var(--background);
            color: var(--foreground);
          }

          /* ── Scrollbar ───────────────────────────── */
          ::-webkit-scrollbar { width: 6px; height: 6px; }
          ::-webkit-scrollbar-track { background: var(--surface); }
          ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
          ::-webkit-scrollbar-thumb:hover { background: var(--muted); }
          * { scrollbar-width: thin; scrollbar-color: #27272a #18181b; }

          /* ── Focus ring ──────────────────────────── */
          :focus-visible {
            outline: 2px solid var(--accent);
            outline-offset: 2px;
          }

          /* ── Selection ───────────────────────────── */
          ::selection {
            background: rgba(245, 158, 11, 0.25);
            color: inherit;
          }

          /* ── Animations ──────────────────────────── */
          @keyframes fade-in {
            from { opacity: 0; transform: translateY(4px); }
            to { opacity: 1; transform: translateY(0); }
          }
          .animate-fade-in {
            animation: fade-in 0.2s ease-out;
          }

          @keyframes fade-in-up {
            from { opacity: 0; transform: translateY(12px); }
            to { opacity: 1; transform: translateY(0); }
          }
          .animate-fade-in-up {
            animation: fade-in-up 0.3s ease-out;
          }

          @keyframes slide-in-right {
            from { opacity: 0; transform: translateX(100%); }
            to { opacity: 1; transform: translateX(0); }
          }
          .animate-slide-in-right {
            animation: slide-in-right 0.3s ease-out;
          }

          @keyframes slide-in-left {
            from { opacity: 0; transform: translateX(-16px); }
            to { opacity: 1; transform: translateX(0); }
          }
          .animate-slide-in-left {
            animation: slide-in-left 0.2s ease-out;
          }

          @keyframes pulse-dot {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.4; }
          }
          .animate-pulse-dot {
            animation: pulse-dot 2s ease-in-out infinite;
          }

          @keyframes shimmer {
            0% { background-position: -200% center; }
            100% { background-position: 200% center; }
          }
          .animate-shimmer {
            background: linear-gradient(90deg, transparent 30%, rgba(255,255,255,0.03) 50%, transparent 70%);
            background-size: 200% 100%;
            animation: shimmer 2s ease-in-out infinite;
          }

          /* ── Accent bar for activity items ───────── */
          .accent-bar {
            position: relative;
          }
          .accent-bar::before {
            content: '';
            position: absolute;
            left: 0;
            top: 6px;
            bottom: 6px;
            width: 2px;
            border-radius: 2px;
            background: currentColor;
            opacity: 0.5;
          }

          /* ── Quota bar glow ──────────────────────── */
          .bar-glow-green { box-shadow: 0 0 6px rgba(34, 197, 94, 0.2); }
          .bar-glow-amber { box-shadow: 0 0 6px rgba(245, 158, 11, 0.2); }
          .bar-glow-red   { box-shadow: 0 0 6px rgba(239, 68, 68, 0.2); }

          /* ── Responsive ──────────────────────────── */
          @media (max-width: 1024px) {
            .lg-grid-4 { grid-template-columns: repeat(2, 1fr) !important; }
            .lg-grid-sidebar { grid-template-columns: 1fr !important; }
          }
          @media (max-width: 768px) {
            .lg-grid-4 { grid-template-columns: 1fr !important; }
          }
        </style>
      </head>
      <body class="h-full font-mono antialiased">
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

          // Keyboard shortcuts
          document.addEventListener('keydown', function(e) {
            if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;
            const views = {
              '1': 'dashboard', '2': 'agents', '3': 'activity',
              '4': 'messaging', '5': 'quotas', '6': 'settings'
            };
            if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
              e.preventDefault();
              liveSocket.main.channel.push('event', {
                type: 'click', event: 'toggle_command_palette', value: {}
              });
            } else if (views[e.key]) {
              liveSocket.main.channel.push('event', {
                type: 'click', event: 'navigate', value: { view: views[e.key] }
              });
            }
          });
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
