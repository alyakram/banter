defmodule Banter.Chat.AttachmentTest do
  # No DB access — these assert on changeset validation only, which runs
  # during for_create/3 before anything is persisted.
  use ExUnit.Case, async: true

  alias Banter.Chat.Attachment

  defp changeset(content_type) do
    Ash.Changeset.for_create(Attachment, :create, %{
      filename: "photo.png",
      size: 1024,
      content_type: content_type,
      storage_path: "servers/a/channels/b/c.png",
      url: "/uploads/servers/a/channels/b/c.png"
    })
  end

  defp content_type_error?(changeset) do
    Enum.any?(changeset.errors, fn error ->
      Map.get(error, :field) == :content_type or :content_type in Map.get(error, :fields, [])
    end)
  end

  test "accepts the raster image formats" do
    for type <- ~w(image/jpeg image/png image/gif image/webp) do
      refute content_type_error?(changeset(type)), "expected #{type} to be accepted"
    end
  end

  test "rejects image/svg+xml even though it matches an image/* prefix" do
    # The whole point of the allowlist: SVG is XML that can carry <script>,
    # and attachments are served same-origin (AUDIT_FINDINGS.md #8).
    assert content_type_error?(changeset("image/svg+xml"))
  end

  test "rejects other script-capable types that claim to be images" do
    for type <- ~w(text/html application/xhtml+xml image/svg) do
      assert content_type_error?(changeset(type)), "expected #{type} to be rejected"
    end
  end

  test "rejects a missing content type" do
    assert content_type_error?(changeset(nil))
  end
end
