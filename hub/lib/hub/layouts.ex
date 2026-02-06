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

          /* ── Slide-in panel ──────────────────────── */
          @keyframes slideInRight {
            from { opacity: 0; transform: translateX(20px); }
            to { opacity: 1; transform: translateX(0); }
          }
          .slide-in-right { animation: slideInRight 0.25s ease-out; }

          @keyframes slideInLeft {
            from { opacity: 0; transform: translateX(-20px); }
            to { opacity: 1; transform: translateX(0); }
          }
          .slide-in-left { animation: slideInLeft 0.25s ease-out; }

          /* ── View transition ─────────────────────── */
          .view-transition {
            animation: viewFade 0.2s ease-out;
          }
          @keyframes viewFade {
            from { opacity: 0.7; }
            to { opacity: 1; }
          }

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
          ::-webkit-scrollbar { width: 5px; height: 5px; }
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
            animation: toastIn 0.3s ease-out, toastOut 0.3s ease-in 3s forwards;
          }
          @keyframes toastIn {
            from { opacity: 0; transform: translateY(-8px) scale(0.95); }
            to { opacity: 1; transform: translateY(0) scale(1); }
          }
          @keyframes toastOut {
            to { opacity: 0; transform: translateY(-4px) scale(0.98); }
          }

          /* ── Transitions ─────────────────────────── */
          .transition-smooth {
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
          }

          /* ── Skeleton loading ────────────────────── */
          @keyframes skeletonPulse {
            0%, 100% { opacity: 0.4; }
            50% { opacity: 0.7; }
          }
          .animate-pulse {
            animation: skeletonPulse 1.5s ease-in-out infinite;
          }

          /* ── Table styles ────────────────────────── */
          table tbody tr {
            transition: background-color 0.15s ease;
          }

          /* ── Responsive adjustments ──────────────── */
          @media (max-width: 1024px) {
            .grid-cols-4 {
              grid-template-columns: repeat(2, 1fr);
            }
            .grid-cols-\[1fr_380px\] {
              grid-template-columns: 1fr;
            }
          }

          @media (max-width: 768px) {
            .grid-cols-4 {
              grid-template-columns: 1fr;
            }
          }

          /* ── Selection highlight ─────────────────── */
          ::selection {
            background: rgba(245, 158, 11, 0.25);
            color: #fff;
          }

          /* ── Keyboard shortcut ───────────────────── */
          kbd {
            font-family: 'JetBrains Mono', monospace;
            font-size: 10px;
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

          // Keyboard shortcuts
          document.addEventListener('keydown', function(e) {
            // Skip if typing in an input/textarea
            if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA') return;

            const views = {'1': 'dashboard', '2': 'agents', '3': 'activity', '4': 'messaging', '5': 'quotas', '6': 'settings'};
            if (views[e.key]) {
              liveSocket.main.channel.push('event', {
                type: 'click',
                event: 'navigate',
                value: { view: views[e.key] }
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
