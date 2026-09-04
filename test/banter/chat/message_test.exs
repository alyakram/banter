defmodule Banter.Chat.MessageTest do
  use Banter.DataCase, async: true

  import Banter.Fixtures

  alias Banter.Chat
  alias Banter.Chat.Message

  defp send_message(attrs, opts) do
    Message
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(opts)
  end

  defp message_attrs(channel, author, extra \\ %{}) do
    Map.merge(%{channel_id: channel.id, author_id: author.id, content: "hello"}, extra)
  end

  setup do
    author = user_fixture()
    {server, _} = server_with_owner_fixture(author)
    channel = channel_fixture(server, author)

    %{author: author, server: server, channel: channel}
  end

  describe "create" do
    test "a member can post to a channel in their server", %{author: author, channel: channel} do
      assert {:ok, message} = send_message(message_attrs(channel, author), actor: author)

      assert message.content == "hello"
      assert message.author_id == author.id
      assert message.channel_id == channel.id
    end

    test "a non-member cannot post to the channel", %{channel: channel} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               send_message(message_attrs(channel, outsider), actor: outsider)
    end

    test "a member cannot post as somebody else", %{author: author, server: server, channel: channel} do
      impersonator = user_fixture()
      member_fixture(impersonator, server)

      # Even a legitimate member of the same server must not be able to forge
      # authorship, since author_id is a client-supplied argument.
      assert {:error, %Ash.Error.Forbidden{}} =
               send_message(message_attrs(channel, author), actor: impersonator)
    end

    test "posting with no actor is forbidden", %{author: author, channel: channel} do
      assert {:error, %Ash.Error.Forbidden{}} = send_message(message_attrs(channel, author), [])
    end

    test "cannot post to a channel that doesn't exist", %{author: author} do
      assert {:error, %Ash.Error.Forbidden{}} =
               send_message(
                 %{channel_id: Ash.UUID.generate(), author_id: author.id, content: "ghost"},
                 actor: author
               )
    end

    test "cannot post to a deleted channel", %{author: author, channel: channel} do
      {:ok, _} = Ash.destroy(channel, actor: author)

      assert {:error, %Ash.Error.Forbidden{}} =
               send_message(message_attrs(channel, author), actor: author)
    end

    test "requires channel_id and author_id", %{author: author, channel: channel} do
      assert {:error, e1} =
               send_message(%{author_id: author.id, content: "x"}, actor: author)

      assert :channel_id in error_fields(e1)

      assert {:error, e2} =
               send_message(%{channel_id: channel.id, content: "x"}, actor: author)

      assert :author_id in error_fields(e2)
    end

    test "defaults message_type to :default and pinned to false", %{
      author: author,
      channel: channel
    } do
      assert {:ok, message} = send_message(message_attrs(channel, author), actor: author)

      assert message.message_type == :default
      assert message.pinned == false
      assert message.edited_at == nil
    end

    test "rejects a message with neither content nor attachments", %{
      author: author,
      channel: channel
    } do
      assert {:error, error} =
               send_message(message_attrs(channel, author, %{content: nil}), actor: author)

      assert :content in error_fields(error)
    end

    test "rejects whitespace-only content", %{author: author, channel: channel} do
      assert {:error, error} =
               send_message(message_attrs(channel, author, %{content: "   "}), actor: author)

      assert :content in error_fields(error)
    end

    test "rejects content longer than 4000 characters", %{author: author, channel: channel} do
      assert {:error, error} =
               send_message(
                 message_attrs(channel, author, %{content: String.duplicate("a", 4001)}),
                 actor: author
               )

      assert :content in error_fields(error)
    end

    test "accepts a nonce for client-side deduplication", %{author: author, channel: channel} do
      assert {:ok, message} =
               send_message(message_attrs(channel, author, %{nonce: "client-123"}), actor: author)

      assert message.nonce == "client-123"
    end

    test "a reply records the message it replies to", %{author: author, channel: channel} do
      {:ok, original} = send_message(message_attrs(channel, author), actor: author)

      assert {:ok, reply} =
               send_message(
                 message_attrs(channel, author, %{
                   content: "replying",
                   reply_to_id: original.id,
                   message_type: :reply
                 }),
                 actor: author
               )

      assert reply.reply_to_id == original.id
      assert reply.message_type == :reply
    end

    test "rejects a message_type outside the enum", %{author: author, channel: channel} do
      assert {:error, error} =
               send_message(message_attrs(channel, author, %{message_type: :shout}), actor: author)

      assert :message_type in error_fields(error)
    end
  end

  describe "read" do
    setup %{author: author, channel: channel} do
      {:ok, message} = send_message(message_attrs(channel, author), actor: author)
      %{message: message}
    end

    test "a member can read messages in their server", %{author: author, message: message} do
      assert {:ok, messages} = Ash.read(Message, actor: author)
      assert message.id in Enum.map(messages, & &1.id)
    end

    test "a non-member cannot read the channel's messages", %{message: _message} do
      outsider = user_fixture()

      assert {:ok, []} = Ash.read(Message, actor: outsider)
    end

    test "reading with no actor returns nothing", %{message: _message} do
      assert {:ok, []} = Ash.read(Message)
    end

    test "messages in servers you don't belong to stay hidden", %{author: author} do
      other = user_fixture()
      {other_server, _} = server_with_owner_fixture(other)
      other_channel = channel_fixture(other_server, other)
      {:ok, hidden} = send_message(message_attrs(other_channel, other), actor: other)

      assert {:ok, messages} = Ash.read(Message, actor: author)
      refute hidden.id in Enum.map(messages, & &1.id)
    end

    test "a member who leaves loses access to the messages", %{
      author: author,
      server: server,
      message: message
    } do
      joiner = user_fixture()
      membership = member_fixture(joiner, server)

      assert {:ok, visible} = Ash.read(Message, actor: joiner)
      assert message.id in Enum.map(visible, & &1.id)

      :ok = Ash.destroy(membership, actor: joiner)

      assert {:ok, []} = Ash.read(Message, actor: joiner)
      # ...and the author still sees it
      assert {:ok, [_]} = Ash.read(Message, actor: author)
    end
  end

  describe "by_id" do
    test "a member can fetch a message by id", %{author: author, channel: channel} do
      {:ok, message} = send_message(message_attrs(channel, author), actor: author)

      assert {:ok, found} = Chat.get_message(message.id, actor: author)
      assert found.id == message.id
    end

    test "a non-member gets nothing back", %{author: author, channel: channel} do
      outsider = user_fixture()
      {:ok, message} = send_message(message_attrs(channel, author), actor: author)

      assert {:error, %Ash.Error.Invalid{}} = Chat.get_message(message.id, actor: outsider)
    end
  end

  describe "by_channel" do
    test "returns the channel's messages newest first", %{author: author, channel: channel} do
      {:ok, first} = send_message(message_attrs(channel, author, %{content: "1"}), actor: author)
      {:ok, second} = send_message(message_attrs(channel, author, %{content: "2"}), actor: author)
      {:ok, third} = send_message(message_attrs(channel, author, %{content: "3"}), actor: author)

      assert {:ok, messages} =
               Chat.list_channel_messages(%{channel_id: channel.id}, actor: author)

      assert Enum.map(messages, & &1.id) == [third.id, second.id, first.id]
    end

    test "only returns messages from the requested channel", %{
      author: author,
      server: server,
      channel: channel
    } do
      other_channel = channel_fixture(server, author)
      {:ok, here} = send_message(message_attrs(channel, author), actor: author)
      {:ok, elsewhere} = send_message(message_attrs(other_channel, author), actor: author)

      assert {:ok, messages} =
               Chat.list_channel_messages(%{channel_id: channel.id}, actor: author)

      ids = Enum.map(messages, & &1.id)
      assert here.id in ids
      refute elsewhere.id in ids
    end

    test "fetches at most 51 rows — 50 displayed plus one to detect more", %{
      author: author,
      channel: channel
    } do
      for n <- 1..55 do
        {:ok, _} =
          send_message(message_attrs(channel, author, %{content: "msg #{n}"}), actor: author)
      end

      assert {:ok, messages} =
               Chat.list_channel_messages(%{channel_id: channel.id}, actor: author)

      assert length(messages) == 51
    end

    test "before_id pages backwards through older messages", %{
      author: author,
      channel: channel
    } do
      messages =
        for n <- 1..5 do
          {:ok, m} =
            send_message(message_attrs(channel, author, %{content: "msg #{n}"}), actor: author)

          m
        end

      [_first, second, third, _fourth, fifth] = messages

      assert {:ok, older} =
               Chat.list_channel_messages(
                 %{channel_id: channel.id, before_id: third.id},
                 actor: author
               )

      ids = Enum.map(older, & &1.id)

      # UUID v7 ids are time-ordered, so "before" the third message means the
      # two created before it — and nothing created after.
      assert second.id in ids
      refute third.id in ids
      refute fifth.id in ids
    end

    test "a non-member gets nothing back", %{author: author, channel: channel} do
      outsider = user_fixture()
      {:ok, _} = send_message(message_attrs(channel, author), actor: author)

      assert {:ok, []} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: outsider)
    end
  end

  describe "pinned_in_channel" do
    test "returns only pinned messages", %{author: author, channel: channel} do
      {:ok, pinned} = send_message(message_attrs(channel, author, %{content: "pin me"}), actor: author)
      {:ok, _plain} = send_message(message_attrs(channel, author, %{content: "ignore"}), actor: author)

      {:ok, pinned} = pin(pinned, author)

      assert {:ok, results} =
               Message
               |> Ash.Query.for_read(:pinned_in_channel, %{channel_id: channel.id})
               |> Ash.read(actor: author)

      assert Enum.map(results, & &1.id) == [pinned.id]
    end

    test "a non-member gets nothing back", %{author: author, channel: channel} do
      outsider = user_fixture()
      {:ok, message} = send_message(message_attrs(channel, author), actor: author)
      {:ok, _} = pin(message, author)

      assert {:ok, []} =
               Message
               |> Ash.Query.for_read(:pinned_in_channel, %{channel_id: channel.id})
               |> Ash.read(actor: outsider)
    end
  end

  describe "update" do
    setup %{author: author, channel: channel} do
      {:ok, message} = send_message(message_attrs(channel, author), actor: author)
      %{message: message}
    end

    test "the author can edit their own message", %{author: author, message: message} do
      assert {:ok, updated} =
               message
               |> Ash.Changeset.for_update(:update, %{content: "edited"})
               |> Ash.update(actor: author)

      assert updated.content == "edited"
    end

    test "editing stamps edited_at", %{author: author, message: message} do
      assert message.edited_at == nil

      {:ok, updated} =
        message
        |> Ash.Changeset.for_update(:update, %{content: "edited"})
        |> Ash.update(actor: author)

      assert updated.edited_at
    end

    test "another member of the same server cannot edit it", %{server: server, message: message} do
      other = user_fixture()
      member_fixture(other, server)

      assert {:error, %Ash.Error.Forbidden{}} =
               message
               |> Ash.Changeset.for_update(:update, %{content: "hijacked"})
               |> Ash.update(actor: other)
    end

    test "editing with no actor is forbidden", %{message: message} do
      assert {:error, %Ash.Error.Forbidden{}} =
               message
               |> Ash.Changeset.for_update(:update, %{content: "hijacked"})
               |> Ash.update()
    end

    test "content validations still apply on edit", %{author: author, message: message} do
      assert {:error, error} =
               message
               |> Ash.Changeset.for_update(:update, %{content: String.duplicate("a", 4001)})
               |> Ash.update(actor: author)

      assert :content in error_fields(error)
    end
  end

  describe "pin and unpin" do
    setup %{author: author, channel: channel} do
      {:ok, message} = send_message(message_attrs(channel, author), actor: author)
      %{message: message}
    end

    test "the author can pin and unpin their message", %{author: author, message: message} do
      assert {:ok, pinned} = pin(message, author)
      assert pinned.pinned == true

      assert {:ok, unpinned} =
               pinned
               |> Ash.Changeset.for_update(:unpin, %{})
               |> Ash.update(actor: author)

      assert unpinned.pinned == false
    end

    test "only the author can pin — not even the server owner", %{
      server: server,
      message: message
    } do
      # Pinning is author-gated rather than moderator-gated, which is a
      # narrower rule than Discord's. Pinned so the current behavior is
      # explicit; see AUDIT_FINDINGS.md on role-based permissions.
      other = user_fixture()
      member_fixture(other, server)

      assert {:error, %Ash.Error.Forbidden{}} = pin(message, other)
    end

    test "pinning with no actor is forbidden", %{message: message} do
      assert {:error, %Ash.Error.Forbidden{}} =
               message |> Ash.Changeset.for_update(:pin, %{}) |> Ash.update()
    end
  end

  describe "destroy" do
    setup %{author: author, channel: channel} do
      {:ok, message} = send_message(message_attrs(channel, author), actor: author)
      %{message: message}
    end

    test "the author can delete their message, which archives it", %{
      author: author,
      message: message
    } do
      assert {:ok, archived} = Ash.destroy(message, actor: author)
      assert archived.archived_at
    end

    test "a deleted message no longer appears in the channel", %{
      author: author,
      channel: channel,
      message: message
    } do
      {:ok, _} = Ash.destroy(message, actor: author)

      assert {:ok, []} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: author)
    end

    test "another member cannot delete someone else's message", %{
      server: server,
      message: message
    } do
      other = user_fixture()
      member_fixture(other, server)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(message, actor: other)
    end

    test "deleting with no actor is forbidden", %{message: message} do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(message)
    end
  end

  describe "paper trail" do
    test "editing a message records a version", %{author: author, channel: channel} do
      {:ok, message} = send_message(message_attrs(channel, author), actor: author)

      {:ok, _} =
        message
        |> Ash.Changeset.for_update(:update, %{content: "edited once"})
        |> Ash.update(actor: author)

      {:ok, versions} = Ash.read(Banter.Chat.Message.Version, authorize?: false)

      assert Enum.any?(versions, fn v ->
               v.version_source_id == message.id and v.content == "edited once"
             end)
    end
  end

  # Helpers

  defp pin(message, actor) do
    message
    |> Ash.Changeset.for_update(:pin, %{})
    |> Ash.update(actor: actor)
  end

  defp error_fields(%{errors: errors}) do
    Enum.flat_map(errors, fn
      %{field: field} when not is_nil(field) -> [field]
      %{fields: fields} when is_list(fields) -> fields
      _ -> []
    end)
  end

  defp error_fields(_), do: []
end
