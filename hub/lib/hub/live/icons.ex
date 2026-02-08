defmodule Hub.Live.Icons do
  @moduledoc """
  Lucide SVG icons for the Ringforge dashboard.
  Each function returns a HEEx template with the SVG.
  All icons: 24x24 viewBox, stroke-based, currentColor.
  """
  use Phoenix.Component

  attr :class, :string, default: "w-4 h-4"

  def zap(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"></polygon>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def layout_dashboard(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect width="7" height="9" x="3" y="3" rx="1"></rect>
      <rect width="7" height="5" x="14" y="3" rx="1"></rect>
      <rect width="7" height="9" x="14" y="12" rx="1"></rect>
      <rect width="7" height="5" x="3" y="16" rx="1"></rect>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def bot(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 8V4H8"></path>
      <rect width="16" height="12" x="4" y="8" rx="2"></rect>
      <path d="M2 14h2"></path>
      <path d="M20 14h2"></path>
      <path d="M15 13v2"></path>
      <path d="M9 13v2"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def activity(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M22 12h-4l-3 9L9 3l-3 9H2"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def message_square(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def gauge(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m12 14 4-4"></path>
      <path d="M3.34 19a10 10 0 1 1 17.32 0"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def settings(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"></path>
      <circle cx="12" cy="12" r="3"></circle>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def search(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="11" cy="11" r="8"></circle>
      <path d="m21 21-4.3-4.3"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def menu(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <line x1="4" x2="20" y1="12" y2="12"></line>
      <line x1="4" x2="20" y1="6" y2="6"></line>
      <line x1="4" x2="20" y1="18" y2="18"></line>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def x(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M18 6 6 18"></path>
      <path d="m6 6 12 12"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def users(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"></path>
      <circle cx="9" cy="7" r="4"></circle>
      <path d="M22 21v-2a4 4 0 0 0-3-3.87"></path>
      <path d="M16 3.13a4 4 0 0 1 0 7.75"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def send(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m22 2-7 20-4-9-9-4Z"></path>
      <path d="M22 2 11 13"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def brain(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 5a3 3 0 1 0-5.997.125 4 4 0 0 0-2.526 5.77 4 4 0 0 0 .556 6.588A4 4 0 1 0 12 18Z"></path>
      <path d="M12 5a3 3 0 1 1 5.997.125 4 4 0 0 1 2.526 5.77 4 4 0 0 1-.556 6.588A4 4 0 1 1 12 18Z"></path>
      <path d="M15 13a4.5 4.5 0 0 1-3-4 4.5 4.5 0 0 1-3 4"></path>
      <path d="M17.599 6.5a3 3 0 0 0 .399-1.375"></path>
      <path d="M6.003 5.125A3 3 0 0 0 6.401 6.5"></path>
      <path d="M3.477 10.896a4 4 0 0 1 .585-.396"></path>
      <path d="M19.938 10.5a4 4 0 0 1 .585.396"></path>
      <path d="M6 18a4 4 0 0 1-1.967-.516"></path>
      <path d="M19.967 17.484A4 4 0 0 1 18 18"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def database(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <ellipse cx="12" cy="5" rx="9" ry="3"></ellipse>
      <path d="M3 5V19A9 3 0 0 0 21 19V5"></path>
      <path d="M3 12A9 3 0 0 0 21 12"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def layers(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"></path>
      <path d="m22.54 12.43-1.96-.89L12 15.42l-8.58-3.88-1.96.89a1 1 0 0 0 0 1.83l8.58 3.9a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"></path>
      <path d="m22.54 16.43-1.96-.89L12 19.42l-8.58-3.88-1.96.89a1 1 0 0 0 0 1.83l8.58 3.9a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def wifi(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 20h.01"></path>
      <path d="M2 8.82a15 15 0 0 1 20 0"></path>
      <path d="M5 12.859a10 10 0 0 1 14 0"></path>
      <path d="M8.5 16.429a5 5 0 0 1 7 0"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def arrow_right(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M5 12h14"></path>
      <path d="m12 5 7 7-7 7"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def log_in(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"></path>
      <polyline points="10 17 15 12 10 7"></polyline>
      <line x1="15" x2="3" y1="12" y2="12"></line>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def log_out(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"></path>
      <polyline points="16 17 21 12 16 7"></polyline>
      <line x1="21" x2="9" y1="12" y2="12"></line>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def shield(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def keyboard(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect width="20" height="16" x="2" y="4" rx="2" ry="2"></rect>
      <path d="M6 8h.001"></path>
      <path d="M10 8h.001"></path>
      <path d="M14 8h.001"></path>
      <path d="M18 8h.001"></path>
      <path d="M8 12h.001"></path>
      <path d="M12 12h.001"></path>
      <path d="M16 12h.001"></path>
      <path d="M7 16h10"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def radio(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M4.9 19.1C1 15.2 1 8.8 4.9 4.9"></path>
      <path d="M7.8 16.2c-2.3-2.3-2.3-6.1 0-8.4"></path>
      <circle cx="12" cy="12" r="2"></circle>
      <path d="M16.2 7.8c2.3 2.3 2.3 6.1 0 8.4"></path>
      <path d="M19.1 4.9C23 8.8 23 15.1 19.1 19"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def network(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="16" y="16" width="6" height="6" rx="1"></rect>
      <rect x="2" y="16" width="6" height="6" rx="1"></rect>
      <rect x="9" y="2" width="6" height="6" rx="1"></rect>
      <path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"></path>
      <path d="M12 12V8"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def circle_dot(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="12" cy="12" r="10"></circle>
      <circle cx="12" cy="12" r="1"></circle>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def plug(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 22v-5"></path>
      <path d="M9 8V2"></path>
      <path d="M15 8V2"></path>
      <path d="M18 8v5a6 6 0 0 1-6 6v0a6 6 0 0 1-6-6V8z"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def clock(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="12" cy="12" r="10"></circle>
      <polyline points="12 6 12 12 16 14"></polyline>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def bar_chart(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <line x1="12" x2="12" y1="20" y2="10"></line>
      <line x1="18" x2="18" y1="20" y2="4"></line>
      <line x1="6" x2="6" y1="20" y2="16"></line>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def globe(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="12" cy="12" r="10"></circle>
      <path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"></path>
      <path d="M2 12h20"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def inbox(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <polyline points="22 12 16 12 14 15 10 15 8 12 2 12"></polyline>
      <path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>
    </svg>
    """
  end

  def pencil(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M17 3a2.85 2.83 0 1 1 4 4L7.5 20.5 2 22l1.5-5.5Z"></path>
      <path d="m15 5 4 4"></path>
    </svg>
    """
  end

  def trash(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M3 6h18"></path>
      <path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"></path>
      <path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"></path>
    </svg>
    """
  end

  def copy(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect width="14" height="14" x="8" y="8" rx="2" ry="2"></rect>
      <path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"></path>
    </svg>
    """
  end

  def alert_triangle(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3Z"></path>
      <path d="M12 9v4"></path>
      <path d="M12 17h.01"></path>
    </svg>
    """
  end

  def user_plus(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"></path>
      <circle cx="9" cy="7" r="4"></circle>
      <line x1="19" x2="19" y1="8" y2="14"></line>
      <line x1="22" x2="16" y1="11" y2="11"></line>
    </svg>
    """
  end

  def key(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="7.5" cy="15.5" r="5.5"></circle>
      <path d="m21 2-9.3 9.3"></path>
      <path d="M18.5 5.5 20 7l-2 2"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def plus(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M5 12h14"></path>
      <path d="M12 5v14"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def clipboard(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect width="8" height="4" x="8" y="2" rx="1" ry="1"></rect>
      <path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def check(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M20 6 9 17l-5-5"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def terminal(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <polyline points="4 17 10 11 4 5"></polyline>
      <line x1="12" x2="20" y1="19" y2="19"></line>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def code(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <polyline points="16 18 22 12 16 6"></polyline>
      <polyline points="8 6 2 12 8 18"></polyline>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def package(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m7.5 4.27 9 5.15"></path>
      <path d="M21 8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16Z"></path>
      <path d="m3.3 7 8.7 5 8.7-5"></path>
      <path d="M12 22V12"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def arrow_left(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m12 19-7-7 7-7"></path>
      <path d="M19 12H5"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def loader(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M21 12a9 9 0 1 1-6.219-8.56"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def hard_drive(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <line x1="22" y1="12" x2="2" y2="12"></line>
      <path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"></path>
      <line x1="6" y1="16" x2="6.01" y2="16"></line>
      <line x1="10" y1="16" x2="10.01" y2="16"></line>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def credit_card(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="1" y="4" width="22" height="16" rx="2" ry="2"></rect>
      <line x1="1" y1="10" x2="23" y2="10"></line>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def github(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 0C5.374 0 0 5.373 0 12c0 5.302 3.438 9.8 8.207 11.387.599.111.793-.261.793-.577v-2.234c-3.338.726-4.033-1.416-4.033-1.416-.546-1.387-1.333-1.756-1.333-1.756-1.089-.745.083-.729.083-.729 1.205.084 1.839 1.237 1.839 1.237 1.07 1.834 2.807 1.304 3.492.997.107-.775.418-1.305.762-1.604-2.665-.305-5.467-1.334-5.467-5.931 0-1.311.469-2.381 1.236-3.221-.124-.303-.535-1.524.117-3.176 0 0 1.008-.322 3.301 1.23A11.509 11.509 0 0112 5.803c1.02.005 2.047.138 3.006.404 2.291-1.552 3.297-1.23 3.297-1.23.653 1.653.242 2.874.118 3.176.77.84 1.235 1.911 1.235 3.221 0 4.609-2.807 5.624-5.479 5.921.43.372.823 1.102.823 2.222v3.293c0 .319.192.694.801.576C20.566 21.797 24 17.3 24 12c0-6.627-5.373-12-12-12z"/>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def google(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="currentColor">
      <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 01-2.2 3.32v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.1z" fill="#4285F4"/>
      <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="#34A853"/>
      <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" fill="#FBBC05"/>
      <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="#EA4335"/>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def mail(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect width="20" height="16" x="2" y="4" rx="2"></rect>
      <path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def ticket(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2Z"></path>
      <path d="M13 5v2"></path>
      <path d="M13 17v2"></path>
      <path d="M13 11v2"></path>
    </svg>
    """
  end

  def webhook(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M18 16.98h1a2 2 0 0 0 1.85-2.75l-2.35-5.3a2 2 0 0 0-1.85-1.25H6.35a2 2 0 0 0-1.85 1.25l-2.35 5.3A2 2 0 0 0 4 16.98h1"></path>
      <path d="m12 13-3 5h6l-3-5Z"></path>
      <circle cx="12" cy="8" r="2"></circle>
    </svg>
    """
  end

  def play(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <polygon points="6 3 20 12 6 21 6 3"></polygon>
    </svg>
    """
  end

  def power(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 2v10"></path>
      <path d="M18.4 6.6a9 9 0 1 1-12.77.04"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def server(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect width="20" height="8" x="2" y="2" rx="2" ry="2"></rect>
      <rect width="20" height="8" x="2" y="14" rx="2" ry="2"></rect>
      <line x1="6" x2="6.01" y1="6" y2="6"></line>
      <line x1="6" x2="6.01" y1="18" y2="18"></line>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def cloud(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M17.5 19H9a7 7 0 1 1 6.71-9h1.79a4.5 4.5 0 1 1 0 9Z"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def dollar_sign(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <line x1="12" x2="12" y1="2" y2="22"></line>
      <path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def map_pin(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0Z"></path>
      <circle cx="12" cy="10" r="3"></circle>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def refresh_cw(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"></path>
      <path d="M21 3v5h-5"></path>
      <path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"></path>
      <path d="M8 16H3v5"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def external_link(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M15 3h6v6"></path>
      <path d="M10 14 21 3"></path>
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def eye(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z"></path>
      <circle cx="12" cy="12" r="3"></circle>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def eye_off(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M9.88 9.88a3 3 0 1 0 4.24 4.24"></path>
      <path d="M10.73 5.08A10.43 10.43 0 0 1 12 5c7 0 10 7 10 7a13.16 13.16 0 0 1-1.67 2.68"></path>
      <path d="M6.61 6.61A13.526 13.526 0 0 0 2 12s3 7 10 7a9.74 9.74 0 0 0 5.39-1.61"></path>
      <line x1="2" x2="22" y1="2" y2="22"></line>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def kanban(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M6 5v11"></path>
      <path d="M12 5v6"></path>
      <path d="M18 5v14"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def chevron_right(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m9 18 6-6-6-6"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def chevron_left(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="m15 18-6-6 6-6"></path>
    </svg>
    """
  end

  attr :class, :string, default: "w-4 h-4"

  def grip_vertical(assigns) do
    ~H"""
    <svg class={@class} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <circle cx="9" cy="12" r="1"></circle>
      <circle cx="9" cy="5" r="1"></circle>
      <circle cx="9" cy="19" r="1"></circle>
      <circle cx="15" cy="12" r="1"></circle>
      <circle cx="15" cy="5" r="1"></circle>
      <circle cx="15" cy="19" r="1"></circle>
    </svg>
    """
  end
end
