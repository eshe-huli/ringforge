defmodule Hub.Plugs.SecurityHeaders do
  @moduledoc """
  Plug that adds security headers to all HTTP responses.

  Mitigates common web vulnerabilities:
  - XSS (Content-Security-Policy, X-XSS-Protection)
  - Clickjacking (X-Frame-Options)
  - MIME sniffing (X-Content-Type-Options)
  - Transport downgrade (Strict-Transport-Security)
  - Referrer leakage (Referrer-Policy)
  - Device feature abuse (Permissions-Policy)
  """

  import Plug.Conn

  @behaviour Plug

  @security_headers [
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"},
    {"x-xss-protection", "1; mode=block"},
    {"strict-transport-security", "max-age=31536000; includeSubDomains"},
    {"content-security-policy",
     "default-src 'self'; script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com https://cdn.jsdelivr.net; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src 'self' https://fonts.gstatic.com; connect-src 'self' wss: ws:; img-src 'self' data:"},
    {"referrer-policy", "strict-origin-when-cross-origin"},
    {"permissions-policy", "camera=(), microphone=(), geolocation=()"}
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    Enum.reduce(@security_headers, conn, fn {header, value}, conn ->
      put_resp_header(conn, header, value)
    end)
  end
end
