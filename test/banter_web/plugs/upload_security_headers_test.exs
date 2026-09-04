defmodule BanterWeb.Plugs.UploadSecurityHeadersTest do
  use BanterWeb.ConnCase

  alias BanterWeb.Plugs.UploadSecurityHeaders

  @upload_dir "priv/static/uploads"

  describe "the plug in isolation" do
    test "sets nosniff and a sandboxing CSP on /uploads paths" do
      conn =
        :get
        |> Plug.Test.conn("/uploads/servers/a/channels/b/c.png")
        |> UploadSecurityHeaders.call([])

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    end

    test "leaves non-upload paths alone" do
      conn =
        :get
        |> Plug.Test.conn("/chat")
        |> UploadSecurityHeaders.call([])

      assert get_resp_header(conn, "x-content-type-options") == []
      assert get_resp_header(conn, "content-security-policy") == []
    end
  end

  describe "wired into the endpoint" do
    setup do
      # A real file on disk, so Plug.Static actually serves it — this is what
      # proves the plug runs *before* Plug.Static. If it were plugged after,
      # Plug.Static would have already sent the response and the headers would
      # never make it onto the wire.
      server_id = Ash.UUID.generate()
      rel = Path.join(["servers", server_id, "channels", "test", "pixel.png"])
      full = Path.join(@upload_dir, rel)

      full |> Path.dirname() |> File.mkdir_p!()
      File.write!(full, <<137, 80, 78, 71, 13, 10, 26, 10>>)

      on_exit(fn -> File.rm_rf(Path.join([@upload_dir, "servers", server_id])) end)

      %{url: "/uploads/" <> rel}
    end

    test "an actually-served upload carries both headers", %{conn: conn, url: url} do
      conn = get(conn, url)

      assert conn.status == 200
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    end
  end
end
