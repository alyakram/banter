defmodule Banter.Chat.ChannelTest do
  use Banter.DataCase, async: true

  import Banter.Fixtures

  alias Banter.Chat
  alias Banter.Chat.Channel

  defp create_channel(attrs, opts) do
    Channel
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(opts)
  end

  defp channel_attrs(server, extra \\ %{}) do
    Map.merge(%{name: unique_name("channel"), server_id: server.id}, extra)
  end

  setup do
    owner = user_fixture()
    {server, _} = server_with_owner_fixture(owner)
    %{owner: owner, server: server}
  end

  describe "create" do
    test "a server member can create a channel", %{owner: owner, server: server} do
      assert {:ok, channel} =
               create_channel(channel_attrs(server, %{name: "general"}), actor: owner)

      assert channel.name == "general"
      assert channel.server_id == server.id
    end

    test "any member can create a channel, not just the owner", %{server: server} do
      # Channel management is gated on plain membership, not role — the
      # resource says so explicitly. Pinned here so that if role-gated channel
      # management ever lands, this test is the thing that flags the change.
      member = user_fixture()
      member_fixture(member, server)

      assert {:ok, _channel} = create_channel(channel_attrs(server), actor: member)
    end

    test "a non-member cannot create a channel", %{server: server} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               create_channel(channel_attrs(server), actor: outsider)
    end

    test "creating with no actor is forbidden", %{server: server} do
      assert {:error, %Ash.Error.Forbidden{}} = create_channel(channel_attrs(server), [])
    end

    test "creating against a server that doesn't exist is forbidden", %{owner: owner} do
      # ActorIsServerMember resolves server_id off the changeset and runs a
      # real membership lookup, so a bogus id simply finds no membership.
      assert {:error, %Ash.Error.Forbidden{}} =
               create_channel(
                 %{name: "ghost", server_id: Ash.UUID.generate()},
                 actor: owner
               )
    end

    test "requires a server_id", %{owner: owner} do
      assert {:error, error} =
               Channel
               |> Ash.Changeset.for_create(:create, %{name: "orphan"})
               |> Ash.create(actor: owner)

      assert :server_id in error_fields(error)
    end

    test "defaults type to :text, position to 0 and slowmode to 0", %{
      owner: owner,
      server: server
    } do
      assert {:ok, channel} = create_channel(channel_attrs(server), actor: owner)

      assert channel.type == :text
      assert channel.position == 0
      assert channel.slowmode_seconds == 0
      assert channel.topic == nil
    end

    for type <- [:text, :voice, :announcement] do
      test "accepts the #{type} channel type", %{owner: owner, server: server} do
        assert {:ok, channel} =
                 create_channel(channel_attrs(server, %{type: unquote(type)}), actor: owner)

        assert channel.type == unquote(type)
      end
    end

    test "rejects a type outside the enum", %{owner: owner, server: server} do
      assert {:error, error} =
               create_channel(channel_attrs(server, %{type: :telepathy}), actor: owner)

      assert :type in error_fields(error)
    end

    test "rejects an empty name", %{owner: owner, server: server} do
      assert {:error, error} = create_channel(channel_attrs(server, %{name: ""}), actor: owner)
      assert :name in error_fields(error)
    end

    test "rejects a name longer than 100 characters", %{owner: owner, server: server} do
      assert {:error, error} =
               create_channel(channel_attrs(server, %{name: String.duplicate("a", 101)}),
                 actor: owner
               )

      assert :name in error_fields(error)
    end

    test "rejects a topic longer than 1024 characters", %{owner: owner, server: server} do
      assert {:error, error} =
               create_channel(channel_attrs(server, %{topic: String.duplicate("a", 1025)}),
                 actor: owner
               )

      assert :topic in error_fields(error)
    end

    test "rejects slowmode outside 0..21600", %{owner: owner, server: server} do
      assert {:error, low} =
               create_channel(channel_attrs(server, %{slowmode_seconds: -1}), actor: owner)

      assert :slowmode_seconds in error_fields(low)

      assert {:error, high} =
               create_channel(channel_attrs(server, %{slowmode_seconds: 21_601}), actor: owner)

      assert :slowmode_seconds in error_fields(high)
    end

    test "accepts slowmode at both ends of the allowed range", %{owner: owner, server: server} do
      assert {:ok, min} =
               create_channel(channel_attrs(server, %{slowmode_seconds: 0}), actor: owner)

      assert min.slowmode_seconds == 0

      assert {:ok, max} =
               create_channel(channel_attrs(server, %{slowmode_seconds: 21_600}), actor: owner)

      assert max.slowmode_seconds == 21_600
    end

    test "channel names must be unique within a server", %{owner: owner, server: server} do
      assert {:ok, _} = create_channel(channel_attrs(server, %{name: "general"}), actor: owner)

      assert {:error, error} =
               create_channel(channel_attrs(server, %{name: "general"}), actor: owner)

      assert Enum.any?(error_fields(error), &(&1 in [:name, :server_id]))
    end

    test "the same channel name can be used in a different server", %{
      owner: owner,
      server: server
    } do
      other_owner = user_fixture()
      {other_server, _} = server_with_owner_fixture(other_owner)

      assert {:ok, _} = create_channel(channel_attrs(server, %{name: "general"}), actor: owner)

      assert {:ok, _} =
               create_channel(channel_attrs(other_server, %{name: "general"}), actor: other_owner)
    end

    test "the create_channel code interface enforces the same policy", %{
      owner: owner,
      server: server
    } do
      outsider = user_fixture()

      assert {:ok, channel} =
               Chat.create_channel(%{name: "via-interface", server_id: server.id}, actor: owner)

      assert channel.name == "via-interface"

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.create_channel(%{name: "nope", server_id: server.id}, actor: outsider)
    end
  end

  describe "read" do
    test "a member can read the server's channels", %{owner: owner, server: server} do
      {:ok, channel} = create_channel(channel_attrs(server), actor: owner)

      assert {:ok, channels} = Ash.read(Channel, actor: owner)
      assert channel.id in Enum.map(channels, & &1.id)
    end

    test "a non-member reads nothing", %{owner: owner, server: server} do
      outsider = user_fixture()
      {:ok, _} = create_channel(channel_attrs(server), actor: owner)

      assert {:ok, []} = Ash.read(Channel, actor: outsider)
    end

    test "reading with no actor returns nothing", %{owner: owner, server: server} do
      {:ok, _} = create_channel(channel_attrs(server), actor: owner)

      assert {:ok, []} = Ash.read(Channel)
    end

    test "channels in servers you don't belong to stay hidden", %{owner: owner} do
      other_owner = user_fixture()
      {other_server, _} = server_with_owner_fixture(other_owner)
      {:ok, hidden} = create_channel(channel_attrs(other_server), actor: other_owner)

      assert {:ok, channels} = Ash.read(Channel, actor: owner)
      refute hidden.id in Enum.map(channels, & &1.id)
    end
  end

  describe "by_id" do
    test "a member can fetch a channel by id", %{owner: owner, server: server} do
      {:ok, channel} = create_channel(channel_attrs(server), actor: owner)

      assert {:ok, found} = Chat.get_channel(channel.id, actor: owner)
      assert found.id == channel.id
    end

    test "a non-member gets nothing back", %{owner: owner, server: server} do
      outsider = user_fixture()
      {:ok, channel} = create_channel(channel_attrs(server), actor: owner)

      assert {:error, %Ash.Error.Invalid{}} = Chat.get_channel(channel.id, actor: outsider)
    end
  end

  describe "by_server" do
    test "lists the server's channels ordered by position, then creation time", %{
      owner: owner,
      server: server
    } do
      {:ok, third} = create_channel(channel_attrs(server, %{position: 2}), actor: owner)
      {:ok, first} = create_channel(channel_attrs(server, %{position: 0}), actor: owner)
      {:ok, second} = create_channel(channel_attrs(server, %{position: 1}), actor: owner)

      assert {:ok, channels} = Chat.list_server_channels(%{server_id: server.id}, actor: owner)
      assert Enum.map(channels, & &1.id) == [first.id, second.id, third.id]
    end

    test "ties on position fall back to oldest first", %{owner: owner, server: server} do
      {:ok, older} = create_channel(channel_attrs(server, %{position: 0}), actor: owner)
      {:ok, newer} = create_channel(channel_attrs(server, %{position: 0}), actor: owner)

      assert {:ok, channels} = Chat.list_server_channels(%{server_id: server.id}, actor: owner)
      ids = Enum.map(channels, & &1.id)

      assert Enum.find_index(ids, &(&1 == older.id)) <
               Enum.find_index(ids, &(&1 == newer.id))
    end

    test "a non-member gets nothing back", %{owner: owner, server: server} do
      outsider = user_fixture()
      {:ok, _} = create_channel(channel_attrs(server), actor: owner)

      assert {:ok, []} = Chat.list_server_channels(%{server_id: server.id}, actor: outsider)
    end
  end

  describe "update" do
    setup %{owner: owner, server: server} do
      {:ok, channel} = create_channel(channel_attrs(server, %{name: "general"}), actor: owner)
      %{channel: channel}
    end

    test "a member can update name, topic, position and slowmode", %{
      owner: owner,
      channel: channel
    } do
      assert {:ok, updated} =
               channel
               |> Ash.Changeset.for_update(:update, %{
                 name: "renamed",
                 topic: "A new topic",
                 position: 5,
                 slowmode_seconds: 30
               })
               |> Ash.update(actor: owner)

      assert updated.name == "renamed"
      assert updated.topic == "A new topic"
      assert updated.position == 5
      assert updated.slowmode_seconds == 30
    end

    test "a non-owner member can also update — updates are membership-gated", %{
      server: server,
      channel: channel
    } do
      member = user_fixture()
      member_fixture(member, server)

      assert {:ok, updated} =
               channel
               |> Ash.Changeset.for_update(:update, %{name: "renamed-by-member"})
               |> Ash.update(actor: member)

      assert updated.name == "renamed-by-member"
    end

    test "a non-member cannot update", %{channel: channel} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               channel
               |> Ash.Changeset.for_update(:update, %{name: "hijacked"})
               |> Ash.update(actor: outsider)
    end

    test "updating with no actor is forbidden", %{channel: channel} do
      assert {:error, %Ash.Error.Forbidden{}} =
               channel
               |> Ash.Changeset.for_update(:update, %{name: "hijacked"})
               |> Ash.update()
    end

    test "a channel's type cannot be changed after creation", %{owner: owner, channel: channel} do
      # :type isn't in the update action's accept list, so a text channel can't
      # be converted into a voice channel (which would strand its messages).
      assert {:error, %Ash.Error.Invalid{}} =
               channel
               |> Ash.Changeset.for_update(:update, %{type: :voice})
               |> Ash.update(actor: owner)
    end

    test "validations still apply on update", %{owner: owner, channel: channel} do
      assert {:error, error} =
               channel
               |> Ash.Changeset.for_update(:update, %{slowmode_seconds: 21_601})
               |> Ash.update(actor: owner)

      assert :slowmode_seconds in error_fields(error)
    end

    test "renaming to another channel's name in the same server is rejected", %{
      owner: owner,
      server: server,
      channel: channel
    } do
      {:ok, _other} = create_channel(channel_attrs(server, %{name: "taken"}), actor: owner)

      assert {:error, error} =
               channel
               |> Ash.Changeset.for_update(:update, %{name: "taken"})
               |> Ash.update(actor: owner)

      assert Enum.any?(error_fields(error), &(&1 in [:name, :server_id]))
    end
  end

  describe "destroy" do
    setup %{owner: owner, server: server} do
      {:ok, channel} = create_channel(channel_attrs(server, %{name: "general"}), actor: owner)
      %{channel: channel}
    end

    test "a member can destroy a channel, which archives it", %{owner: owner, channel: channel} do
      assert {:ok, archived} = Ash.destroy(channel, actor: owner)
      assert archived.archived_at
    end

    test "an archived channel is no longer readable", %{
      owner: owner,
      server: server,
      channel: channel
    } do
      {:ok, _} = Ash.destroy(channel, actor: owner)

      assert {:ok, []} = Chat.list_server_channels(%{server_id: server.id}, actor: owner)
      assert {:error, %Ash.Error.Invalid{}} = Chat.get_channel(channel.id, actor: owner)
    end

    test "a non-member cannot destroy", %{channel: channel} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(channel, actor: outsider)
    end

    test "destroying with no actor is forbidden", %{channel: channel} do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(channel)
    end

    test "a channel name can be reused after the original is deleted", %{
      owner: owner,
      server: server,
      channel: channel
    } do
      # Deletion is a soft delete, so without a partial unique index the
      # archived row keeps occupying (name, server_id) and permanently burns
      # the name — delete #general and you can never have a #general again.
      {:ok, _} = Ash.destroy(channel, actor: owner)

      assert {:ok, recreated} =
               create_channel(channel_attrs(server, %{name: "general"}), actor: owner)

      assert recreated.name == "general"
      refute recreated.id == channel.id
    end
  end

  # Helpers

  defp error_fields(%{errors: errors}) do
    Enum.flat_map(errors, fn
      %{field: field} when not is_nil(field) -> [field]
      %{fields: fields} when is_list(fields) -> fields
      _ -> []
    end)
  end

  defp error_fields(_), do: []
end
