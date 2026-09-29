defmodule Banter.Voice.PeerTest do
  # A Peer's exit reason is how its LiveView tells "the user left" from "the
  # connection was lost" from "it never connected". These pin each one.
  use ExUnit.Case, async: true

  alias Banter.Voice.Peer
  alias ExWebRTC.PeerConnection

  # The test process stands in for both the Room and the participant's
  # LiveView, so it receives the Peer's signals.
  defp start_peer(opts \\ []) do
    {:ok, peer} =
      Peer.start_link(
        [
          user_id: "u-#{System.unique_integer()}",
          room_pid: self(),
          lv_pid: self(),
          ice_servers: []
        ] ++ opts
      )

    Process.unlink(peer)
    Process.monitor(peer)
    peer
  end

  # What ExWebRTC tells the Peer about its own PeerConnection.
  defp connection_state(peer, conn_state) do
    pc = :sys.get_state(peer).pc
    send(peer, {:ex_webrtc, pc, {:connection_state_change, conn_state}})
  end

  # A real offer, from a second PeerConnection playing the browser.
  defp browser_offer do
    {:ok, browser} = PeerConnection.start_link()
    {:ok, _transceiver} = PeerConnection.add_transceiver(browser, :audio)
    {:ok, offer} = PeerConnection.create_offer(browser)
    :ok = PeerConnection.set_local_description(browser, offer)
    %{"type" => "offer", "sdp" => offer.sdp}
  end

  test "failing before it ever connected is :connect_failed" do
    peer = start_peer()

    connection_state(peer, :failed)

    assert_receive {:DOWN, _, :process, ^peer, {:shutdown, :connect_failed}}
  end

  test "failing after connecting is :connection_lost, and the view hears when it connects" do
    peer = start_peer()

    connection_state(peer, :connected)
    assert_receive {:voice_connection, :connected}

    connection_state(peer, :failed)
    assert_receive {:DOWN, _, :process, ^peer, {:shutdown, :connection_lost}}
  end

  test "an offer that never leads to a connection times out" do
    peer = start_peer(connect_timeout: 100)

    # Answered, but no ICE candidates are ever exchanged, so it can't connect.
    assert :ok = Peer.process_offer(peer, browser_offer())
    assert_receive {:voice_signal, :answer, _}

    assert_receive {:DOWN, _, :process, ^peer, {:shutdown, :connect_timeout}}, 1_000
  end

  test "the timeout is only counted from the offer" do
    # Waiting on the browser's microphone prompt isn't the connection failing.
    peer = start_peer(connect_timeout: 50)

    refute_receive {:DOWN, _, :process, ^peer, _}, 200
  end

  test "connecting in time disarms the timeout" do
    peer = start_peer(connect_timeout: 100)
    :ok = Peer.process_offer(peer, browser_offer())

    connection_state(peer, :connected)

    refute_receive {:DOWN, _, :process, ^peer, _}, 300
  end

  test "its PeerConnection dying takes the Peer down with it" do
    peer = start_peer()
    pc = :sys.get_state(peer).pc

    # It traps exits, so this used to arrive as a message it ignored — the
    # Peer lived on with no connection.
    Process.exit(pc, :kill)

    assert_receive {:DOWN, _, :process, ^peer, {:shutdown, :peer_connection_down}}
  end
end
