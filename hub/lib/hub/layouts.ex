defmodule Hub.Layouts do
  @moduledoc """
  Root and app layouts for LiveView pages.
  Zinc dark theme with SaladUI CSS variables, JetBrains Mono font.
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
        <script data-cfasync="false" src="https://cdn.tailwindcss.com"></script>
        <script data-cfasync="false">
          tailwind.config = {
            darkMode: 'class',
            theme: {
              extend: {
                fontFamily: {
                  mono: ['JetBrains Mono', 'Fira Code', 'ui-monospace', 'monospace'],
                  sans: ['JetBrains Mono', 'system-ui', 'sans-serif']
                },
                colors: {
                  border: "hsl(var(--border))",
                  input: "hsl(var(--input))",
                  ring: "hsl(var(--ring))",
                  background: "hsl(var(--background))",
                  foreground: "hsl(var(--foreground))",
                  primary: { DEFAULT: "hsl(var(--primary))", foreground: "hsl(var(--primary-foreground))" },
                  secondary: { DEFAULT: "hsl(var(--secondary))", foreground: "hsl(var(--secondary-foreground))" },
                  destructive: { DEFAULT: "hsl(var(--destructive))", foreground: "hsl(var(--destructive-foreground))" },
                  muted: { DEFAULT: "hsl(var(--muted))", foreground: "hsl(var(--muted-foreground))" },
                  accent: { DEFAULT: "hsl(var(--accent))", foreground: "hsl(var(--accent-foreground))" },
                  popover: { DEFAULT: "hsl(var(--popover))", foreground: "hsl(var(--popover-foreground))" },
                  card: { DEFAULT: "hsl(var(--card))", foreground: "hsl(var(--card-foreground))" },
                  'rf-bg': '#09090b',
                  'rf-card': '#111119',
                  'rf-border': '#1a1a2e',
                  'rf-border-bright': '#252540',
                  'rf-accent': '#f59e0b',
                  'rf-accent-dim': '#92610b',
                  'rf-text': '#e2e8f0',
                  'rf-text-sec': '#94a3b8',
                  'rf-text-muted': '#475569',
                },
                borderRadius: {
                  lg: "var(--radius)",
                  md: "calc(var(--radius) - 2px)",
                  sm: "calc(var(--radius) - 4px)",
                },
              }
            }
          }
        </script>
        <style>
          @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:ital,wght@0,300;0,400;0,500;0,600;0,700;1,400&display=swap');

          /* ── Light Theme (default) ──────────────── */
          :root {
            --background: 0 0% 100%;
            --foreground: 240 10% 3.9%;
            --card: 0 0% 100%;
            --card-foreground: 240 10% 3.9%;
            --popover: 0 0% 100%;
            --popover-foreground: 240 10% 3.9%;
            --primary: 240 5.9% 10%;
            --primary-foreground: 0 0% 98%;
            --secondary: 240 4.8% 95.9%;
            --secondary-foreground: 240 5.9% 10%;
            --muted: 240 4.8% 95.9%;
            --muted-foreground: 240 3.8% 46.1%;
            --accent: 240 4.8% 95.9%;
            --accent-foreground: 240 5.9% 10%;
            --destructive: 0 84.2% 60.2%;
            --destructive-foreground: 0 0% 98%;
            --border: 240 5.9% 90%;
            --input: 240 5.9% 90%;
            --ring: 240 5.9% 10%;
            --radius: 0.5rem;
          }

          /* ── Dark Theme ─────────────────────────── */
          .dark {
            --background: 240 10% 3.9%;
            --foreground: 0 0% 98%;
            --card: 240 10% 3.9%;
            --card-foreground: 0 0% 98%;
            --popover: 240 10% 3.9%;
            --popover-foreground: 0 0% 98%;
            --primary: 0 0% 98%;
            --primary-foreground: 240 5.9% 10%;
            --secondary: 240 3.7% 15.9%;
            --secondary-foreground: 0 0% 98%;
            --muted: 240 3.7% 15.9%;
            --muted-foreground: 240 5% 64.9%;
            --accent: 240 3.7% 15.9%;
            --accent-foreground: 0 0% 98%;
            --destructive: 0 62.8% 30.6%;
            --destructive-foreground: 0 0% 98%;
            --border: 240 3.7% 15.9%;
            --input: 240 3.7% 15.9%;
            --ring: 240 4.9% 83.9%;
          }

          body {
            background: hsl(var(--background));
            color: hsl(var(--foreground));
          }

          /* ══ LIGHT MODE — comprehensive overrides for hardcoded dark classes ══ */

          /* Backgrounds */
          :root:not(.dark) .bg-zinc-900 { background-color: #ffffff !important; }
          :root:not(.dark) .bg-zinc-950 { background-color: #f8fafc !important; }
          :root:not(.dark) .bg-zinc-900\/95 { background-color: rgba(255,255,255,0.97) !important; }
          :root:not(.dark) .bg-zinc-900\/50 { background-color: rgba(255,255,255,0.7) !important; }
          :root:not(.dark) .bg-zinc-800 { background-color: #f1f5f9 !important; }
          :root:not(.dark) .bg-zinc-800\/30 { background-color: rgba(241,245,249,0.5) !important; }
          :root:not(.dark) .bg-zinc-800\/50 { background-color: rgba(241,245,249,0.7) !important; }
          :root:not(.dark) .bg-zinc-800\/40 { background-color: rgba(241,245,249,0.6) !important; }
          :root:not(.dark) .bg-zinc-800\/70 { background-color: rgba(241,245,249,0.8) !important; }
          :root:not(.dark) .bg-\[\#09090b\] { background-color: #f8fafc !important; }
          :root:not(.dark) .bg-\[\#111119\] { background-color: #ffffff !important; }
          :root:not(.dark) .hover\:bg-zinc-800\/50:hover { background-color: rgba(241,245,249,0.9) !important; }
          :root:not(.dark) .hover\:bg-zinc-800:hover { background-color: #e2e8f0 !important; }
          :root:not(.dark) .hover\:bg-zinc-900:hover { background-color: #f1f5f9 !important; }

          /* Borders */
          :root:not(.dark) .border-zinc-800 { border-color: #e2e8f0 !important; }
          :root:not(.dark) .border-zinc-800\/50 { border-color: rgba(226,232,240,0.7) !important; }
          :root:not(.dark) .border-zinc-800\/30 { border-color: rgba(226,232,240,0.5) !important; }
          :root:not(.dark) .border-zinc-700 { border-color: #cbd5e1 !important; }
          :root:not(.dark) .border-zinc-700\/50 { border-color: rgba(203,213,225,0.6) !important; }
          :root:not(.dark) .border-zinc-600 { border-color: #94a3b8 !important; }
          :root:not(.dark) .hover\:border-zinc-600:hover { border-color: #94a3b8 !important; }
          :root:not(.dark) .hover\:border-zinc-700:hover { border-color: #cbd5e1 !important; }
          :root:not(.dark) .divide-zinc-800 > :not([hidden]) ~ :not([hidden]) { border-color: #e2e8f0 !important; }
          :root:not(.dark) .divide-zinc-800\/50 > :not([hidden]) ~ :not([hidden]) { border-color: rgba(226,232,240,0.7) !important; }

          /* Text colors */
          :root:not(.dark) .text-zinc-100 { color: #0f172a !important; }
          :root:not(.dark) .text-zinc-200 { color: #1e293b !important; }
          :root:not(.dark) .text-zinc-300 { color: #334155 !important; }
          :root:not(.dark) .text-zinc-400 { color: #64748b !important; }
          :root:not(.dark) .text-zinc-500 { color: #64748b !important; }
          :root:not(.dark) .text-zinc-600 { color: #94a3b8 !important; }
          :root:not(.dark) .hover\:text-zinc-100:hover { color: #0f172a !important; }
          :root:not(.dark) .hover\:text-zinc-200:hover { color: #1e293b !important; }
          :root:not(.dark) .hover\:text-zinc-300:hover { color: #334155 !important; }
          :root:not(.dark) .hover\:text-zinc-400:hover { color: #64748b !important; }
          :root:not(.dark) .placeholder\:text-zinc-600::placeholder { color: #94a3b8 !important; }
          :root:not(.dark) .placeholder\:text-zinc-500::placeholder { color: #94a3b8 !important; }

          /* Accent/status backgrounds */
          :root:not(.dark) .bg-amber-500\/10 { background-color: rgba(245,158,11,0.08) !important; }
          :root:not(.dark) .bg-amber-500\/15 { background-color: rgba(245,158,11,0.1) !important; }
          :root:not(.dark) .bg-amber-500\/5 { background-color: rgba(245,158,11,0.05) !important; }
          :root:not(.dark) .bg-green-500\/10 { background-color: rgba(34,197,94,0.08) !important; }
          :root:not(.dark) .bg-green-500\/15 { background-color: rgba(34,197,94,0.1) !important; }
          :root:not(.dark) .bg-red-500\/10 { background-color: rgba(239,68,68,0.08) !important; }
          :root:not(.dark) .bg-blue-500\/10 { background-color: rgba(59,130,246,0.08) !important; }

          /* Inputs & forms */
          :root:not(.dark) input, :root:not(.dark) textarea, :root:not(.dark) select {
            background-color: #ffffff !important;
            border-color: #cbd5e1 !important;
            color: #0f172a !important;
          }
          :root:not(.dark) input::placeholder, :root:not(.dark) textarea::placeholder {
            color: #94a3b8 !important;
          }
          :root:not(.dark) input:focus, :root:not(.dark) textarea:focus, :root:not(.dark) select:focus {
            border-color: #f59e0b !important;
            box-shadow: 0 0 0 2px rgba(245,158,11,0.15) !important;
          }
          :root:not(.dark) kbd {
            background-color: #f1f5f9 !important;
            border-color: #cbd5e1 !important;
            color: #64748b !important;
          }

          /* Code blocks */
          :root:not(.dark) code { background-color: #f1f5f9 !important; color: #334155 !important; }
          :root:not(.dark) .font-mono.text-\[11px\] { color: #475569 !important; }

          /* Sidebar */
          :root:not(.dark) .bg-grid {
            background-image: radial-gradient(circle at 1px 1px, rgba(0,0,0,0.03) 1px, transparent 0) !important;
            background-size: 32px 32px;
          }
          :root:not(.dark) .bg-radial-glow {
            background: radial-gradient(ellipse at 50% 0%, rgba(245,158,11,0.06) 0%, transparent 60%) !important;
          }
          :root:not(.dark) .glass-card {
            background: rgba(255,255,255,0.9) !important;
            backdrop-filter: blur(12px);
            -webkit-backdrop-filter: blur(12px);
            border: 1px solid #e2e8f0 !important;
          }
          :root:not(.dark) .glass-card:hover {
            background: rgba(255,255,255,0.98) !important;
            border-color: #cbd5e1 !important;
          }

          /* Body override for light mode */
          :root:not(.dark) body { background: #f8fafc !important; color: #0f172a !important; }

          /* Shadow for cards in light mode */
          :root:not(.dark) [class*="card"] {
            box-shadow: 0 1px 3px rgba(0,0,0,0.06), 0 1px 2px rgba(0,0,0,0.04) !important;
          }

          /* Ring / focus colors */
          :root:not(.dark) .ring-zinc-800 { --tw-ring-color: #e2e8f0 !important; }
          :root:not(.dark) .focus\:border-amber-500\/50:focus { border-color: rgba(245,158,11,0.5) !important; }

          /* Amber accent text stays visible */
          :root:not(.dark) .text-amber-400 { color: #d97706 !important; }
          :root:not(.dark) .text-amber-500 { color: #b45309 !important; }
          :root:not(.dark) .hover\:text-amber-400:hover { color: #d97706 !important; }
          :root:not(.dark) .hover\:text-amber-300:hover { color: #f59e0b !important; }
          :root:not(.dark) .border-amber-500\/20 { border-color: rgba(217,119,6,0.25) !important; }
          :root:not(.dark) .border-amber-500\/30 { border-color: rgba(217,119,6,0.3) !important; }
          :root:not(.dark) .border-amber-500\/40 { border-color: rgba(217,119,6,0.4) !important; }

          /* Green accent adjustments */
          :root:not(.dark) .text-green-400 { color: #16a34a !important; }
          :root:not(.dark) .text-red-400 { color: #dc2626 !important; }
          :root:not(.dark) .text-cyan-400 { color: #0891b2 !important; }

          /* Badge & misc dark backgrounds */
          :root:not(.dark) .bg-zinc-700 { background-color: #e2e8f0 !important; }
          :root:not(.dark) .bg-zinc-700\/50 { background-color: rgba(226,232,240,0.6) !important; }
          :root:not(.dark) .bg-zinc-600 { background-color: #cbd5e1 !important; }
          :root:not(.dark) .hover\:bg-zinc-700:hover { background-color: #cbd5e1 !important; }
          :root:not(.dark) .border-zinc-700\/50 { border-color: rgba(203,213,225,0.6) !important; }
          :root:not(.dark) .border-zinc-600\/50 { border-color: rgba(148,163,184,0.5) !important; }

          /* Scrollbar light mode */
          :root:not(.dark) ::-webkit-scrollbar-track { background: #f1f5f9 !important; }
          :root:not(.dark) ::-webkit-scrollbar-thumb { background: #cbd5e1 !important; }
          :root:not(.dark) ::-webkit-scrollbar-thumb:hover { background: #94a3b8 !important; }
          :root:not(.dark) * { scrollbar-color: #cbd5e1 #f1f5f9; }

          /* Selection light mode */
          :root:not(.dark) ::selection { background: rgba(245,158,11,0.2); }

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

          /* ── Transitions ─────────────────────────── */
          .transition-smooth {
            transition: all 0.2s cubic-bezier(0.4, 0, 0.2, 1);
          }

          /* ── Pulse dot ───────────────────────────── */
          .pulse-dot {
            animation: pulse-dot 2s ease-in-out infinite;
          }

          /* ── View transitions ────────────────────── */
          .view-transition > * {
            animation: fade-in 0.15s ease-out;
          }

          /* ── Scrollbar ───────────────────────────── */
          ::-webkit-scrollbar { width: 6px; height: 6px; }
          ::-webkit-scrollbar-track { background: hsl(var(--secondary)); }
          ::-webkit-scrollbar-thumb { background: hsl(var(--border)); border-radius: 3px; }
          ::-webkit-scrollbar-thumb:hover { background: hsl(var(--muted-foreground)); }
          * { scrollbar-width: thin; scrollbar-color: hsl(240 3.7% 15.9%) hsl(240 10% 3.9%); }

          /* ── Focus ring ──────────────────────────── */
          :focus-visible {
            outline: 2px solid #f59e0b;
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
      <body class="h-full font-mono antialiased" id="rf-body" phx-hook="ThemeManager">
        <%= @inner_content %>
        <script data-cfasync="false" src="https://cdn.jsdelivr.net/npm/phoenix@1.8.3/priv/static/phoenix.min.js"></script>
        <script data-cfasync="false" src="https://cdn.jsdelivr.net/npm/phoenix_live_view@1.1.22/priv/static/phoenix_live_view.min.js"></script>
        <script data-cfasync="false">
          // LiveView Hooks
          let Hooks = {}

          // Auto-scroll message thread to bottom
          Hooks.ScrollBottom = {
            mounted() { this.scrollToBottom() },
            updated() { this.scrollToBottom() },
            scrollToBottom() {
              this.el.scrollTop = this.el.scrollHeight
            }
          }

          // ESC key handler for command palette and modals
          Hooks.EscListener = {
            mounted() {
              this.handler = (e) => {
                if (e.key === 'Escape') {
                  this.pushEvent('esc_pressed', {})
                }
              }
              window.addEventListener('keydown', this.handler)
            },
            destroyed() {
              window.removeEventListener('keydown', this.handler)
            }
          }

          // Theme management
          Hooks.ThemeManager = {
            mounted() {
              this.handleEvent("set-theme", ({theme}) => {
                localStorage.setItem("rf-theme", theme);
                this.applyTheme(theme);
              });
              // Apply saved theme on mount
              const saved = localStorage.getItem("rf-theme") || "system";
              this.applyTheme(saved);
            },
            applyTheme(theme) {
              const html = document.documentElement;
              if (theme === "dark") {
                html.classList.add("dark");
              } else if (theme === "light") {
                html.classList.remove("dark");
              } else {
                // system
                if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
                  html.classList.add("dark");
                } else {
                  html.classList.remove("dark");
                }
              }
            }
          }

          // Copy to clipboard
          Hooks.CopyKey = {
            mounted() {
              this.el.addEventListener('click', () => {
                let text = this.el.dataset.key
                navigator.clipboard.writeText(text).then(() => {
                  let orig = this.el.textContent
                  this.el.textContent = 'Copied!'
                  setTimeout(() => { this.el.textContent = orig }, 1500)
                })
              })
            }
          }

          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: { _csrf_token: csrfToken },
            hooks: Hooks
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
