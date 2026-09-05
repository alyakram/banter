defmodule Banter.StorageTest do
  use ExUnit.Case, async: true

  alias Banter.Storage

  @upload_dir "priv/static/uploads"

  # Leading bytes of each accepted format. Uploads are identified by these, so
  # a fixture has to carry real ones — a text file is no longer accepted no
  # matter what content type it claims.
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13>>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF">>
  @gif89 "GIF89a" <> <<1, 0, 1, 0, 0, 0, 0>>
  @gif87 "GIF87a" <> <<1, 0, 1, 0, 0, 0, 0>>
  @webp "RIFF" <> <<36, 0, 0, 0>> <> "WEBPVP8 "

  defp write_temp(content) do
    path = Path.join(System.tmp_dir!(), "storage_test_#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  setup do
    # Real server/channel ids so the test writes into its own subtree of the
    # upload dir and can remove exactly that subtree afterwards.
    server_id = Ash.UUID.generate()
    channel_id = Ash.UUID.generate()

    source = Path.join(System.tmp_dir!(), "storage_test_#{System.unique_integer([:positive])}")
    File.write!(source, @png)

    on_exit(fn ->
      File.rm(source)
      File.rm_rf(Path.join([@upload_dir, "servers", server_id]))
    end)

    %{server_id: server_id, channel_id: channel_id, source: source}
  end

  describe "allowed_content_type?/1" do
    test "accepts the raster formats" do
      for type <- ~w(image/jpeg image/png image/gif image/webp) do
        assert Storage.allowed_content_type?(type), "expected #{type} to be allowed"
      end
    end

    test "rejects SVG in every spelling, and anything else script-capable" do
      for type <- ~w(image/svg+xml image/svg text/html application/xhtml+xml text/xml) do
        refute Storage.allowed_content_type?(type), "expected #{type} to be rejected"
      end
    end

    test "rejects nil rather than blowing up" do
      refute Storage.allowed_content_type?(nil)
    end
  end

  describe "detect_content_type/1" do
    test "identifies each accepted format from its leading bytes" do
      assert {:ok, "image/png"} == Storage.detect_content_type(write_temp(@png))
      assert {:ok, "image/jpeg"} == Storage.detect_content_type(write_temp(@jpeg))
      assert {:ok, "image/gif"} == Storage.detect_content_type(write_temp(@gif89))
      assert {:ok, "image/gif"} == Storage.detect_content_type(write_temp(@gif87))
      assert {:ok, "image/webp"} == Storage.detect_content_type(write_temp(@webp))
    end

    test "refuses content that isn't one of them" do
      for content <- [
            ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|,
            "<!doctype html><html><body>hi</body></html>",
            "%PDF-1.4",
            "plain text"
          ] do
        assert {:error, :unrecognized_content} ==
                 Storage.detect_content_type(write_temp(content)),
               "expected #{inspect(String.slice(content, 0, 20))} to be unrecognized"
      end
    end

    test "refuses a file too short to identify, and an empty one" do
      assert {:error, :unrecognized_content} == Storage.detect_content_type(write_temp(<<0x89>>))
      assert {:error, :unrecognized_content} == Storage.detect_content_type(write_temp(""))
    end

    test "refuses a file that doesn't exist rather than raising" do
      assert {:error, :unrecognized_content} ==
               Storage.detect_content_type("/nonexistent/nope.png")
    end

    test "a near-miss header isn't enough" do
      # RIFF container that isn't WebP (a .wav, say) must not pass as an image.
      wav = "RIFF" <> <<36, 0, 0, 0>> <> "WAVEfmt "
      assert {:error, :unrecognized_content} == Storage.detect_content_type(write_temp(wav))
    end
  end

  describe "upload_file/5 content sniffing" do
    test "refuses a disguised file whose declared type is allowed", ctx do
      # The heart of this: SVG bytes labelled image/png. The label passes the
      # allowlist, so only the bytes can catch it.
      svg = write_temp(~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|)

      assert {:error, :content_type_mismatch} =
               Storage.upload_file(svg, ctx.server_id, ctx.channel_id, "innocent.png", "image/png")

      refute File.exists?(Path.join([@upload_dir, "servers", ctx.server_id]))
    end

    test "refuses HTML disguised as an image", ctx do
      html = write_temp("<!doctype html><script>alert(1)</script>")

      assert {:error, :content_type_mismatch} =
               Storage.upload_file(html, ctx.server_id, ctx.channel_id, "x.gif", "image/gif")
    end

    test "the bytes decide the stored type when the declaration disagrees", ctx do
      # A real JPEG announced as a PNG. It's a format we accept, so it's stored
      # — but as what it actually is, so the extension and the Content-Type
      # Plug.Static later derives from it are both truthful.
      jpeg = write_temp(@jpeg)

      assert {:ok, result} =
               Storage.upload_file(jpeg, ctx.server_id, ctx.channel_id, "photo.png", "image/png")

      assert result.content_type == "image/jpeg"
      assert Path.extname(result.storage_path) == ".jpg"
    end

    test "returns the detected content type on the happy path", ctx do
      png = write_temp(@png)

      assert {:ok, result} =
               Storage.upload_file(png, ctx.server_id, ctx.channel_id, "photo.png", "image/png")

      assert result.content_type == "image/png"
    end

    test "an unsupported declared type is still rejected before the bytes are read", ctx do
      # A genuine PNG offered as SVG: refused on the declaration alone, which
      # keeps the existing early-reject behaviour intact.
      png = write_temp(@png)

      assert {:error, :unsupported_content_type} =
               Storage.upload_file(png, ctx.server_id, ctx.channel_id, "x.svg", "image/svg+xml")
    end
  end

  describe "upload_file/5" do
    test "stores an allowed file and returns its path and url", ctx do
      assert {:ok, result} =
               Storage.upload_file(ctx.source, ctx.server_id, ctx.channel_id, "photo.png", "image/png")

      assert result.storage_path =~ "servers/#{ctx.server_id}/channels/#{ctx.channel_id}/"
      assert result.url == "/" <> Path.join("uploads", result.storage_path)
      assert File.exists?(Path.join(@upload_dir, result.storage_path))
    end

    test "rejects an SVG content type without writing anything to disk", ctx do
      assert {:error, :unsupported_content_type} =
               Storage.upload_file(
                 ctx.source,
                 ctx.server_id,
                 ctx.channel_id,
                 "payload.svg",
                 "image/svg+xml"
               )

      refute File.exists?(Path.join([@upload_dir, "servers", ctx.server_id]))
    end

    test "derives the stored extension from the file's actual type, not the filename", ctx do
      # The filename is fully attacker-controlled; the extension it would have
      # produced is exactly what Plug.Static later derives the response
      # Content-Type from, so it must not be trusted.
      assert {:ok, result} =
               Storage.upload_file(
                 ctx.source,
                 ctx.server_id,
                 ctx.channel_id,
                 "payload.svg",
                 "image/png"
               )

      assert Path.extname(result.storage_path) == ".png"
      refute result.storage_path =~ ".svg"
    end
  end
end
