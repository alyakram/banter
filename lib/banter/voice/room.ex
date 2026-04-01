defmodule Banter.Voice.Room do
  @moduledoc """
  GenServer managing a voice channel room.

  One process per active voice channel, supervised via VoiceRoomSupervisor.
  Creates and monitors Voice.Peer processes, routes RTP between participants.
  Auto-terminates after an idle timeout.

  ## Architecture
  Each participant has ONE Voice.Peer (one PeerConnection to/from the server).
  Audio RTP flows: Browser A → Peer A → Room → Peer B → Browser B.
  When participants join/leave, existing Peers renegotiate to add/remove sender tracks.
  """

  use GenServer
  require Logger

  alias Banter.Voice.Peer

  @idle_timeout :timer.minutes(5)

  # ── Client API ─────────────────────────────────────────────────────

  def start_link(opts) do
    channel_id = Keyword.fetch!(opts, :channel_id)
    GenServer.start_link(__MODULE__, channel_id, name: via(channel_id))
  end

  def ensure_started(channel_id) do
    case Registry.lookup(Banter.VoiceRoomRegistry, channel_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          Banter.VoiceRoomSupervisor,
          {__MODULE__, channel_id: channel_id}
        )
    end
  end

  @doc """
  Join (or rejoin on page refresh) a voice channel.
  Returns `{:ok, peer_pid}` where peer_pid is the Voice.Peer for this user.
  The caller should store peer_pid to route signaling events.
  """
  def join(channel_id, user_id, lv_pid) do
    with {:ok, _} <- ensure_started(channel_id) do
      GenServer.call(via(channel_id), {:join, user_id, lv_pid})
    end
  end

  @doc "Remove a participant from the voice room."
  def leave(channel_id, user_id) do
    case Registry.lookup(Banter.VoiceRoomRegistry, channel_id) do
      [{_, _}] -> GenServer.call(via(channel_id), {:leave, user_id})
      [] -> :ok
    end
  end

  @doc "Returns the list of participant user_ids."
  def participants(channel_id) do
    case Registry.lookup(Banter.VoiceRoomRegistry, channel_id) do
      [{_, _}] -> GenServer.call(via(channel_id), :participants)
      [] -> []
    end
  end

  # ── Server Callbacks ───────────────────────────────────────────────

  @impl true
  def init(channel_id) do
    Logger.info("Voice.Room starting for channel=#{channel_id}")

    ice_servers =
      Application.get_env(:banter, :webrtc, [])
      |> Keyword.get(:ice_servers, [%{urls: "stun:stun.l.google.com:19302"}])

    {:ok, %{
      channel_id: channel_id,
      participants: %{},   # %{user_id => peer_pid}
      monitors: %{}        # %{ref => user_id}
    }, {:continue, {:set_ice_servers, ice_servers}}}
  end

  @impl true
  def handle_continue({:set_ice_servers, ice_servers}, state) do
    {:noreply, Map.put(state, :ice_servers, ice_servers), @idle_timeout}
  end

  @impl true
  def handle_call({:join, user_id, lv_pid}, _from, state) do
    # Clean up any stale Peer for this user (handles page refresh gracefully)
    {is_reconnect, state} = maybe_stop_peer(state, user_id)

    {:ok, peer_pid} = Peer.start_link(
      user_id: user_id,
      room_pid: self(),
      lv_pid: lv_pid,
      ice_servers: state.ice_servers
    )

    # Unlink so a Peer crash/shutdown doesn't propagate an exit signal to the Room.
    # The monitor below is sufficient for cleanup notifications.
    Process.unlink(peer_pid)
    ref = Process.monitor(peer_pid)

    # Wire up sender tracks between the new peer and all existing peers
    Enum.each(state.participants, fn {existing_uid, existing_peer} ->
      # Existing peer: add fresh sender for the (re)joining user
      if is_reconnect, do: Peer.remove_sender(existing_peer, user_id)
      Peer.add_sender(existing_peer, user_id)

      # New peer: add sender for each existing participant
      Peer.add_sender(peer_pid, existing_uid)
    end)

    new_state = %{state |
      participants: Map.put(state.participants, user_id, peer_pid),
      monitors: Map.put(state.monitors, ref, user_id)
    }

    Logger.info("Voice.Room #{state.channel_id}: #{user_id} joined (#{map_size(new_state.participants)} total)")

    {:reply, {:ok, peer_pid}, new_state, @idle_timeout}
  end

  @impl true
  def handle_call({:leave, user_id}, _from, state) do
    {_is_reconnect, state} = maybe_stop_peer(state, user_id)

    # Tell remaining peers to remove the sender for the departed user
    Enum.each(state.participants, fn {_, peer} ->
      Peer.remove_sender(peer, user_id)
    end)

    Logger.info("Voice.Room #{state.channel_id}: #{user_id} left (#{map_size(state.participants)} remaining)")

    {:reply, :ok, state, @idle_timeout}
  end

  @impl true
  def handle_call(:participants, _from, state) do
    {:reply, Map.keys(state.participants), state, @idle_timeout}
  end

  # RTP fan-out: called by Voice.Peer when audio arrives from a browser
  @impl true
  def handle_cast({:forward_rtp, from_user_id, packet}, state) do
    Enum.each(state.participants, fn {user_id, peer_pid} ->
      if user_id != from_user_id do
        Peer.forward_rtp(peer_pid, from_user_id, packet)
      end
    end)

    {:noreply, state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info("Voice.Room #{state.channel_id}: idle, shutting down")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state, @idle_timeout}

      {user_id, new_monitors} ->
        Logger.warning("Voice.Peer for #{user_id} crashed (#{inspect(reason)}), removing")

        remaining = Map.delete(state.participants, user_id)

        Enum.each(remaining, fn {_, peer} ->
          Peer.remove_sender(peer, user_id)
        end)

        {:noreply, %{state | participants: remaining, monitors: new_monitors}, @idle_timeout}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state, @idle_timeout}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Voice.Room #{state.channel_id} terminating: #{inspect(reason)}")

    Enum.each(state.participants, fn {_, peer_pid} ->
      if Process.alive?(peer_pid) do
        try do
          GenServer.stop(peer_pid, :shutdown)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  # ── Private ────────────────────────────────────────────────────────

  defp via(channel_id) do
    {:via, Registry, {Banter.VoiceRoomRegistry, channel_id}}
  end

  # Stops the existing Peer for user_id if present. Returns {was_reconnect, new_state}.
  defp maybe_stop_peer(state, user_id) do
    case Map.get(state.participants, user_id) do
      nil ->
        {false, state}

      old_pid ->
        # Find and demonitor the existing monitor ref for this user
        {old_ref, new_monitors} =
          Enum.find_value(state.monitors, {nil, state.monitors}, fn
            {ref, ^user_id} -> {ref, Map.delete(state.monitors, ref)}
            _ -> nil
          end)

        if old_ref, do: Process.demonitor(old_ref, [:flush])
        if Process.alive?(old_pid) do
          try do
            GenServer.stop(old_pid, :shutdown)
          catch
            :exit, _ -> :ok
          end
        end

        {true, %{state |
          participants: Map.delete(state.participants, user_id),
          monitors: new_monitors
        }}
    end
  end
end
