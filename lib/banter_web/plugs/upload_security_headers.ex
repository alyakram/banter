defmodule BanterWeb.Plugs.UploadSecurityHeaders do
  @moduledoc """
  Hardens responses for user-uploaded files served out of `/uploads`.

  Uploads are written by users and served same-origin, and nothing inspects
  the *bytes* of an upload — only its declared content type. So a file whose
  contents don't match its extension (SVG or HTML stored as `.png`) would
  otherwise be a stored-XSS vector the moment a browser decides to render it
  as a document. Two headers close that:

    * `X-Content-Type-Options: nosniff` — the browser must honour the declared
      `Content-Type` rather than sniffing the bytes and upgrading them to HTML.

    * `Content-Security-Policy: default-src 'none'; sandbox` — even if such a
      response is rendered as a document, `sandbox` drops it into a unique
      opaque origin with scripts disabled, so it cannot reach this app's
      cookies, DOM, or authenticated endpoints.

  Inline `<img>` rendering is unaffected: both headers constrain what a
  *document* may do, not whether an image decodes.

  Must be plugged **before** the `/uploads` `Plug.Static`, which sends the
  response itself — response headers set afterwards would never be applied.

  See AUDIT_FINDINGS.md #8.
  """

  @behaviour Plug

  import Plug.Conn, only: [put_resp_header: 3]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["uploads" | _]} = conn, _opts) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
  end

  def call(conn, _opts), do: conn
end
