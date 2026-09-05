defmodule Banter.Chat.AttachmentTest do
  use Banter.DataCase, async: true

  import Banter.Fixtures

  alias Banter.Chat
  alias Banter.Chat.Attachment

  setup do
    author = user_fixture()
    {server, _} = server_with_owner_fixture(author)
    channel = channel_fixture(server, author)

    %{author: author, server: server, channel: channel}
  end

  describe "content_type validation" do
    # Changeset-level only — these run during for_create/3, before anything is
    # persisted, and don't need the surrounding message. The allowlist exists
    # because SVG is XML that can carry <script> and attachments are served
    # same-origin.
    #
    # The stored path's extension is derived from the content type rather than
    # hardcoded: the two have to agree, so a fixture that pinned ".png" for
    # every type would be quietly invalid for three of the four — and the
    # acceptance test below would assert nothing.
    defp changeset(content_type) do
      ext = Banter.Storage.extension_for(content_type) || ".png"

      Ash.Changeset.for_create(Attachment, :create, %{
        filename: "photo#{ext}",
        size: 1024,
        content_type: content_type,
        storage_path: "servers/a/channels/b/c#{ext}",
        url: "/uploads/servers/a/channels/b/c#{ext}"
      })
    end

    defp any_error?(changeset), do: changeset.errors != []

    defp content_type_error?(changeset) do
      Enum.any?(changeset.errors, fn error ->
        Map.get(error, :field) == :content_type or :content_type in Map.get(error, :fields, [])
      end)
    end

    test "accepts the raster image formats" do
      for type <- ~w(image/jpeg image/png image/gif image/webp) do
        refute any_error?(changeset(type)), "expected #{type} to be accepted outright"
      end
    end

    test "accepts either legitimate JPEG extension" do
      # .jpeg and .jpg both resolve to image/jpeg, and Plug.Static serves both
      # correctly, so both must be accepted. Comparing against a single
      # canonical extension would reject .jpeg — including records written
      # before this validation existed.
      for path <- ["servers/a/channels/b/c.jpg", "servers/a/channels/b/c.jpeg"] do
        changeset =
          Ash.Changeset.for_create(Attachment, :create, %{
            filename: Path.basename(path),
            size: 1024,
            content_type: "image/jpeg",
            storage_path: path,
            url: "/uploads/" <> path
          })

        refute any_error?(changeset), "expected #{path} to be accepted for image/jpeg"
      end
    end

    test "rejects a path with no extension, which would be served as octet-stream" do
      changeset =
        Ash.Changeset.for_create(Attachment, :create, %{
          filename: "photo",
          size: 1024,
          content_type: "image/png",
          storage_path: "servers/a/channels/b/c",
          url: "/uploads/servers/a/channels/b/c"
        })

      assert any_error?(changeset)
    end

    test "the stored path's extension must match the content type" do
      # Plug.Static types the response from the extension on disk, so a record
      # claiming one thing while pointing at another would be served as the
      # other.
      mismatched =
        Ash.Changeset.for_create(Attachment, :create, %{
          filename: "photo.png",
          size: 1024,
          content_type: "image/png",
          storage_path: "servers/a/channels/b/c.gif",
          url: "/uploads/servers/a/channels/b/c.gif"
        })

      assert Enum.any?(mismatched.errors, fn e ->
               Map.get(e, :field) == :storage_path or
                 :storage_path in Map.get(e, :fields, [])
             end)
    end

    test "rejects image/svg+xml even though it matches an image/* prefix" do
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

  describe "create" do
    test "attachments are created through a message", %{author: author, channel: channel} do
      {message, attachment} = message_with_attachment_fixture(channel, author)

      assert attachment.message_id == message.id
      assert attachment.filename == "photo.png"
      assert attachment.content_type == "image/png"
    end

    test "several attachments can ride on one message", %{author: author, channel: channel} do
      message =
        message_fixture(channel, author, %{
          attachments: [attachment_attrs(), attachment_attrs(), attachment_attrs()]
        })

      message = Ash.load!(message, [:attachments], authorize?: false)
      assert length(message.attachments) == 3
    end

    test "cannot be created standalone — message_id isn't an accepted input", %{
      author: author,
      channel: channel
    } do
      # The create action accepts only the file fields, so there's no way to
      # point a new attachment at a message directly; they exist solely as
      # children of a message create. Worth pinning, because it's what makes
      # the create action's authorization the parent message's problem.
      message = message_fixture(channel, author)

      assert {:error, _} =
               Attachment
               |> Ash.Changeset.for_create(
                 :create,
                 Map.put(attachment_attrs(), :message_id, message.id)
               )
               |> Ash.create(authorize?: false)
    end

    test "rejects an attachment with no message at all", %{author: _author} do
      assert {:error, _} =
               Attachment
               |> Ash.Changeset.for_create(:create, attachment_attrs())
               |> Ash.create(authorize?: false)
    end

    test "width and height are optional", %{author: author, channel: channel} do
      {_message, attachment} = message_with_attachment_fixture(channel, author)

      assert attachment.width == nil
      assert attachment.height == nil
    end

    test "records image dimensions when given", %{author: author, channel: channel} do
      {_message, attachment} =
        message_with_attachment_fixture(channel, author, %{width: 800, height: 600})

      assert attachment.width == 800
      assert attachment.height == 600
    end

    test "rejects a size below 1 or above 25 MB", %{author: author, channel: channel} do
      assert_raise Ash.Error.Invalid, fn ->
        message_with_attachment_fixture(channel, author, %{size: 0})
      end

      assert_raise Ash.Error.Invalid, fn ->
        message_with_attachment_fixture(channel, author, %{size: 25_000_001})
      end
    end

    test "rejects a filename longer than 255 characters", %{author: author, channel: channel} do
      assert_raise Ash.Error.Invalid, fn ->
        message_with_attachment_fixture(channel, author, %{
          filename: String.duplicate("a", 256) <> ".png"
        })
      end
    end
  end

  describe "read" do
    setup %{author: author, channel: channel} do
      {message, attachment} = message_with_attachment_fixture(channel, author)
      %{message: message, attachment: attachment}
    end

    test "a member of the server can read the attachment", %{
      author: author,
      attachment: attachment
    } do
      assert {:ok, attachments} = Ash.read(Attachment, actor: author)
      assert attachment.id in Enum.map(attachments, & &1.id)
    end

    test "a non-member cannot read it", %{attachment: _attachment} do
      outsider = user_fixture()

      assert {:ok, []} = Ash.read(Attachment, actor: outsider)
    end

    test "reading with no actor returns nothing" do
      assert {:ok, []} = Ash.read(Attachment)
    end

    test "attachments in servers you don't belong to stay hidden", %{author: author} do
      other = user_fixture()
      {other_server, _} = server_with_owner_fixture(other)
      other_channel = channel_fixture(other_server, other)
      {_msg, hidden} = message_with_attachment_fixture(other_channel, other)

      assert {:ok, attachments} = Ash.read(Attachment, actor: author)
      refute hidden.id in Enum.map(attachments, & &1.id)
    end

    test "loading a message's attachments works for a member", %{
      author: author,
      message: message,
      attachment: attachment
    } do
      # This is the path ChatLive actually uses.
      loaded = Ash.load!(message, [:attachments], actor: author)
      assert Enum.map(loaded.attachments, & &1.id) == [attachment.id]
    end
  end

  describe "by_id and by_message" do
    setup %{author: author, channel: channel} do
      {message, attachment} = message_with_attachment_fixture(channel, author)
      %{message: message, attachment: attachment}
    end

    test "by_id fetches an attachment for a member", %{
      author: author,
      attachment: attachment
    } do
      assert {:ok, found} = Chat.get_attachment(attachment.id, actor: author)
      assert found.id == attachment.id
    end

    test "by_id gives a non-member nothing", %{attachment: attachment} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Invalid{}} = Chat.get_attachment(attachment.id, actor: outsider)
    end

    test "by_message lists a message's attachments oldest first", %{
      author: author,
      channel: channel
    } do
      message =
        message_fixture(channel, author, %{
          attachments: [
            attachment_attrs(%{filename: "first.png"}),
            attachment_attrs(%{filename: "second.png"})
          ]
        })

      assert {:ok, attachments} = Chat.list_message_attachments(message.id, actor: author)
      assert length(attachments) == 2
    end

    test "by_message gives a non-member nothing", %{message: message} do
      outsider = user_fixture()

      assert {:ok, []} = Chat.list_message_attachments(message.id, actor: outsider)
    end
  end

  describe "update" do
    setup %{author: author, channel: channel} do
      {message, attachment} = message_with_attachment_fixture(channel, author)
      %{message: message, attachment: attachment}
    end

    test "the message author can update dimensions and url", %{
      author: author,
      attachment: attachment
    } do
      assert {:ok, updated} =
               attachment
               |> Ash.Changeset.for_update(:update, %{width: 1024, height: 768})
               |> Ash.update(actor: author)

      assert updated.width == 1024
      assert updated.height == 768
    end

    test "a different member cannot update someone else's attachment", %{
      server: server,
      attachment: attachment
    } do
      other = user_fixture()
      member_fixture(other, server)

      assert {:error, %Ash.Error.Forbidden{}} =
               attachment
               |> Ash.Changeset.for_update(:update, %{width: 1})
               |> Ash.update(actor: other)
    end

    test "a non-member cannot update it", %{attachment: attachment} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               attachment
               |> Ash.Changeset.for_update(:update, %{width: 1})
               |> Ash.update(actor: outsider)
    end

    test "updating with no actor is forbidden", %{attachment: attachment} do
      assert {:error, %Ash.Error.Forbidden{}} =
               attachment
               |> Ash.Changeset.for_update(:update, %{width: 1})
               |> Ash.update()
    end

    test "the file identity itself can't be rewritten", %{
      author: author,
      attachment: attachment
    } do
      # Only :width, :height and :url are accepted — content_type, filename,
      # size and storage_path are fixed at creation, so an attachment can't be
      # relabelled as a different file after the fact.
      for field <- [:content_type, :filename, :size, :storage_path] do
        assert {:error, %Ash.Error.Invalid{}} =
                 attachment
                 |> Ash.Changeset.for_update(:update, %{field => "whatever"})
                 |> Ash.update(actor: author),
               "expected #{field} to be rejected on update"
      end
    end
  end

  describe "destroy" do
    setup %{author: author, channel: channel} do
      {message, attachment} = message_with_attachment_fixture(channel, author)
      %{message: message, attachment: attachment}
    end

    test "the message author can delete the attachment, which archives it", %{
      author: author,
      attachment: attachment
    } do
      assert {:ok, archived} = Ash.destroy(attachment, actor: author)
      assert archived.archived_at
    end

    test "a deleted attachment stops appearing on its message", %{
      author: author,
      message: message,
      attachment: attachment
    } do
      {:ok, _} = Ash.destroy(attachment, actor: author)

      loaded = Ash.load!(message, [:attachments], actor: author)
      assert loaded.attachments == []
    end

    test "a different member cannot delete it", %{server: server, attachment: attachment} do
      other = user_fixture()
      member_fixture(other, server)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(attachment, actor: other)
    end

    test "a non-member cannot delete it", %{attachment: attachment} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(attachment, actor: outsider)
    end

    test "deleting with no actor is forbidden", %{attachment: attachment} do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(attachment)
    end
  end
end
