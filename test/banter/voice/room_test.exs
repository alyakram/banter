defmodule Banter.Voice.RoomTest do
  use ExUnit.Case, async: true

  alias Banter.Voice.Room

  # Rooms are keyed on channel id alone, so any fresh id gets its own room.
  setup do
    %{channel_id: Ash.UUID.generate(), user_id: Ash.UUID.generate()}
  end

  defp join(channel_id, user_id) do
    {:ok, peer} = Room.join(channel_id, user_id, self())
    Process.monitor(peer)
    peer
  end

  test "rejoining replaces the old Peer, and says so", %{channel_id: channel, user_id: user} do
    first = join(channel, user)
    second = join(channel, user)

    # A page refresh or a second tab. The LiveView that owned the first Peer
    # must not take this for a lost connection.
    assert_receive {:DOWN, _, :process, ^first, {:shutdown, :replaced}}
    assert Process.alive?(second)
    assert Room.participants(channel) == [user]
  end

  test "leaving stops the Peer with :left", %{channel_id: channel, user_id: user} do
    peer = join(channel, user)

    :ok = Room.leave(channel, user)

    assert_receive {:DOWN, _, :process, ^peer, {:shutdown, :left}}
    assert Room.participants(channel) == []
  end

  test "a Peer that ends on its own is dropped from the room", %{
    channel_id: channel,
    user_id: user
  } do
    other = Ash.UUID.generate()
    lost = join(channel, user)
    _stays = join(channel, other)

    GenServer.stop(lost, {:shutdown, :connection_lost})
    assert_receive {:DOWN, _, :process, ^lost, _}

    assert Room.participants(channel) == [other]
  end
end
