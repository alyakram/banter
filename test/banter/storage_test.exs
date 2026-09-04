defmodule Banter.StorageTest do
  use ExUnit.Case, async: true

  alias Banter.Storage

  @upload_dir "priv/static/uploads"

  setup do
    # Real server/channel ids so the test writes into its own subtree of the
    # upload dir and can remove exactly that subtree afterwards.
    server_id = Ash.UUID.generate()
    channel_id = Ash.UUID.generate()

    source = Path.join(System.tmp_dir!(), "storage_test_#{System.unique_integer([:positive])}")
    File.write!(source, "not really an image, but the bytes don't matter here")

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

    test "derives the stored extension from the content type, not the filename", ctx do
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
