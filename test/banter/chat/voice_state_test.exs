defmodule Banter.Chat.VoiceStateTest do
  use Banter.DataCase, async: true

  import Banter.Fixtures

  alias Banter.Chat
  alias Banter.Chat.VoiceState

  defp join(attrs, opts) do
    VoiceState
    |> Ash.Changeset.for_create(:join, attrs)
    |> Ash.create(opts)
  end

  defp join_attrs(user, channel, server, extra \\ %{}) do
    Map.merge(
      %{user_id: user.id, channel_id: channel.id, server_id: server.id},
      extra
    )
  end

  setup do
    user = user_fixture()
    {server, _} = server_with_owner_fixture(user)
    channel = channel_fixture(server, user, %{type: :voice})

    %{user: user, server: server, channel: channel}
  end

  describe "join" do
    test "a member can join a voice channel in their server", %{
      user: user,
      server: server,
      channel: channel
    } do
      assert {:ok, state} = join(join_attrs(user, channel, server), actor: user)

      assert state.user_id == user.id
      assert state.channel_id == channel.id
      assert state.server_id == server.id
    end

    test "defaults self_mute and self_deaf to false", %{
      user: user,
      server: server,
      channel: channel
    } do
      assert {:ok, state} = join(join_attrs(user, channel, server), actor: user)

      assert state.self_mute == false
      assert state.self_deaf == false
    end

    test "can join already muted or deafened", %{user: user, server: server, channel: channel} do
      assert {:ok, state} =
               join(join_attrs(user, channel, server, %{self_mute: true, self_deaf: true}),
                 actor: user
               )

      assert state.self_mute == true
      assert state.self_deaf == true
    end

    test "cannot join on someone else's behalf", %{server: server, channel: channel} do
      impersonator = user_fixture()
      member_fixture(impersonator, server)
      victim = user_fixture()
      member_fixture(victim, server)

      assert {:error, %Ash.Error.Forbidden{}} =
               join(join_attrs(victim, channel, server), actor: impersonator)
    end

    test "a non-member cannot join", %{server: server, channel: channel} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               join(join_attrs(outsider, channel, server), actor: outsider)
    end

    test "joining with no actor is forbidden", %{user: user, server: server, channel: channel} do
      assert {:error, %Ash.Error.Forbidden{}} = join(join_attrs(user, channel, server), [])
    end

    test "cannot join a voice channel belonging to a server you're not in", %{user: user} do
      # The dangerous case. channel_id arrives from the client (the phx-click
      # payload) while server_id comes from the session's current server, and
      # nothing tied them together — so passing a foreign channel_id alongside
      # your own server_id satisfied both create policies. The LiveView then
      # calls Voice.Room.join/3 with that channel_id, and Voice.Room is keyed
      # purely on channel_id with no authorization of its own: you land in the
      # live audio session of a server you don't belong to.
      stranger = user_fixture()
      {foreign_server, _} = server_with_owner_fixture(stranger)
      foreign_channel = channel_fixture(foreign_server, stranger, %{type: :voice})

      {own_server, _} = server_with_owner_fixture(user)

      # Passing your own server_id alongside their channel: caught by the
      # validation that the two must describe the same server.
      assert {:error, %Ash.Error.Invalid{}} =
               join(
                 %{
                   user_id: user.id,
                   channel_id: foreign_channel.id,
                   server_id: own_server.id
                 },
                 actor: user
               )
    end

    test "cannot join a foreign voice channel even naming its real server", %{user: user} do
      # The same attack with the ids made self-consistent, so the validation
      # has nothing to object to. This is the authorization layer on its own:
      # membership is checked against the channel's actual server, which the
      # actor doesn't belong to.
      stranger = user_fixture()
      {foreign_server, _} = server_with_owner_fixture(stranger)
      foreign_channel = channel_fixture(foreign_server, stranger, %{type: :voice})

      assert {:error, %Ash.Error.Forbidden{}} =
               join(join_attrs(user, foreign_channel, foreign_server), actor: user)
    end

    test "cannot join a text channel as voice", %{user: user, server: server} do
      text_channel = channel_fixture(server, user, %{type: :text})

      assert {:error, error} = join(join_attrs(user, text_channel, server), actor: user)
      assert :channel_id in error_fields(error)
    end

    test "cannot claim a server_id that isn't the channel's own server", %{
      user: user,
      channel: channel
    } do
      # Same mismatch from the other direction: a channel you *can* reach, but
      # attributed to a different server, which would misfile the row for every
      # membership-gated read that filters on server_id.
      {other_server, _} = server_with_owner_fixture(user)

      assert {:error, _} =
               join(
                 %{user_id: user.id, channel_id: channel.id, server_id: other_server.id},
                 actor: user
               )
    end

    test "requires user_id, channel_id and server_id", %{
      user: user,
      server: server,
      channel: channel
    } do
      assert {:error, e1} =
               join(%{channel_id: channel.id, server_id: server.id}, actor: user)

      assert :user_id in error_fields(e1)

      assert {:error, e2} = join(%{user_id: user.id, server_id: server.id}, actor: user)
      assert :channel_id in error_fields(e2)

      assert {:error, e3} = join(%{user_id: user.id, channel_id: channel.id}, actor: user)
      assert :server_id in error_fields(e3)
    end

    test "a user can only be in one voice channel at a time", %{
      user: user,
      server: server,
      channel: channel
    } do
      second_channel = channel_fixture(server, user, %{type: :voice})

      assert {:ok, _} = join(join_attrs(user, channel, server), actor: user)

      assert {:error, error} = join(join_attrs(user, second_channel, server), actor: user)
      assert :user_id in error_fields(error)
    end

    test "two different users can share a voice channel", %{
      user: user,
      server: server,
      channel: channel
    } do
      second = user_fixture()
      member_fixture(second, server)

      assert {:ok, _} = join(join_attrs(user, channel, server), actor: user)
      assert {:ok, _} = join(join_attrs(second, channel, server), actor: second)
    end
  end

  describe "read" do
    setup %{user: user, server: server, channel: channel} do
      {:ok, state} = join(join_attrs(user, channel, server), actor: user)
      %{state: state}
    end

    test "a member of the server can see who's in voice", %{user: user, state: state} do
      assert {:ok, states} = Ash.read(VoiceState, actor: user)
      assert state.id in Enum.map(states, & &1.id)
    end

    test "another member of the same server can see it too", %{server: server, state: state} do
      other = user_fixture()
      member_fixture(other, server)

      assert {:ok, states} = Ash.read(VoiceState, actor: other)
      assert state.id in Enum.map(states, & &1.id)
    end

    test "a non-member sees nothing" do
      outsider = user_fixture()

      assert {:ok, []} = Ash.read(VoiceState, actor: outsider)
    end

    test "reading with no actor returns nothing" do
      assert {:ok, []} = Ash.read(VoiceState)
    end
  end

  describe "by_channel, by_server and by_user" do
    setup %{user: user, server: server, channel: channel} do
      {:ok, state} = join(join_attrs(user, channel, server), actor: user)
      %{state: state}
    end

    test "by_channel lists occupants of a voice channel", %{
      user: user,
      channel: channel,
      state: state
    } do
      assert {:ok, states} = Chat.list_voice_states_by_channel(channel.id, actor: user)
      assert Enum.map(states, & &1.id) == [state.id]
    end

    test "by_server lists voice states across the server", %{
      user: user,
      server: server,
      state: state
    } do
      assert {:ok, states} = Chat.list_voice_states_by_server(server.id, actor: user)
      assert Enum.map(states, & &1.id) == [state.id]
    end

    test "by_user finds a single user's voice state", %{user: user, state: state} do
      assert {:ok, found} = Chat.get_user_voice_state(user.id, actor: user)
      assert found.id == state.id
    end

    test "a non-member gets nothing from any of them", %{
      user: user,
      server: server,
      channel: channel
    } do
      outsider = user_fixture()

      assert {:ok, []} = Chat.list_voice_states_by_channel(channel.id, actor: outsider)
      assert {:ok, []} = Chat.list_voice_states_by_server(server.id, actor: outsider)
      # by_user is a `get?` action, so its denial surfaces as NotFound rather
      # than an empty result.
      assert {:error, %Ash.Error.Invalid{}} = Chat.get_user_voice_state(user.id, actor: outsider)
    end
  end

  describe "update" do
    setup %{user: user, server: server, channel: channel} do
      {:ok, state} = join(join_attrs(user, channel, server), actor: user)
      %{state: state}
    end

    test "a user can toggle their own mute and deafen", %{user: user, state: state} do
      assert {:ok, muted} =
               state
               |> Ash.Changeset.for_update(:update, %{self_mute: true})
               |> Ash.update(actor: user)

      assert muted.self_mute == true

      assert {:ok, deafened} =
               muted
               |> Ash.Changeset.for_update(:update, %{self_deaf: true, self_mute: true})
               |> Ash.update(actor: user)

      assert deafened.self_deaf == true
    end

    test "another member cannot mute someone else", %{server: server, state: state} do
      other = user_fixture()
      member_fixture(other, server)

      assert {:error, %Ash.Error.Forbidden{}} =
               state
               |> Ash.Changeset.for_update(:update, %{self_mute: true})
               |> Ash.update(actor: other)
    end

    test "updating with no actor is forbidden", %{state: state} do
      assert {:error, %Ash.Error.Forbidden{}} =
               state
               |> Ash.Changeset.for_update(:update, %{self_mute: true})
               |> Ash.update()
    end

    test "a voice state can't be moved to another channel", %{
      user: user,
      server: server,
      state: state
    } do
      # Only the mute/deafen flags are accepted, so channel_id and server_id
      # are fixed at join time — you leave and rejoin instead.
      elsewhere = channel_fixture(server, user, %{type: :voice})

      assert {:error, %Ash.Error.Invalid{}} =
               state
               |> Ash.Changeset.for_update(:update, %{channel_id: elsewhere.id})
               |> Ash.update(actor: user)
    end
  end

  describe "destroy" do
    setup %{user: user, server: server, channel: channel} do
      {:ok, state} = join(join_attrs(user, channel, server), actor: user)
      %{state: state}
    end

    test "a user can leave voice", %{user: user, state: state} do
      assert :ok = Ash.destroy(state, actor: user)
    end

    test "leaving hard-deletes the row — voice state is transient", %{
      user: user,
      channel: channel,
      state: state
    } do
      :ok = Ash.destroy(state, actor: user)

      assert {:ok, []} = Chat.list_voice_states_by_channel(channel.id, actor: user)
    end

    test "leaving frees the user to join another channel", %{
      user: user,
      server: server,
      channel: channel,
      state: state
    } do
      :ok = Ash.destroy(state, actor: user)
      elsewhere = channel_fixture(server, user, %{type: :voice})

      assert {:ok, _} = join(join_attrs(user, elsewhere, server), actor: user)
    end

    test "another member cannot disconnect someone else", %{server: server, state: state} do
      other = user_fixture()
      member_fixture(other, server)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(state, actor: other)
    end

    test "disconnecting with no actor is forbidden", %{state: state} do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(state)
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
