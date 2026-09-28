defmodule Banter.Voice.Peer do
  @moduledoc """
  GenServer wrapping ExWebRTC.PeerConnection for a single voice channel participant.

  Handles WebRTC signaling with the browser via the parent LiveView process,
  receives audio RTP from the browser's microphone, and forwards it to Voice.Room
  for fan-out to other participants.

  ## Signal flow
  - Browser offer → `process_offer/2` → sends answer to LiveView
  - Server-initiated renegotiation → `:negotiation_needed` → sends offer to LiveView
  - LiveView relays all signals via push_event/handle_event

  ## How a Peer ends

  The exit reason says why, so whoever monitors it (the Room, and the
  participant's LiveView) can tell a deliberate stop from a lost connection:

  - `{:shutdown, :left}` / `{:shutdown, :replaced}` — stopped by the Room: the
    user left, or rejoined from another tab or a page refresh.
  - `{:shutdown, :connection_lost}` — it was connected, then failed.
  - `{:shutdown, :connect_failed}` / `{:shutdown, :connect_timeout}` — it never
    connected: ICE failed outright, or nothing came of the browser's offer
    within the connect timeout.
  - `{:shutdown, :peer_connection_down}` — the underlying PeerConnection died.

  It sends `{:voice_connection, :connected}` to the LiveView each time the
  connection comes up.
  """

  use GenServer
  require Logger

  alias ExWebRTC.{PeerConnection, MediaStreamTrack, SessionDescription, ICECandidate}

  @default_ice_servers [%{urls: "stun:stun.l.google.com:19302"}]

  # How long after the browser's offer the connection has to come up. Counted
  # from the offer rather than from start, so time the user spends on the
  # browser's microphone prompt doesn't count against it.
  @connect_timeout :timer.seconds(20)

  # ── Client API ─────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Process a browser-initiated SDP offer; answer is sent back to the LiveView."
  def process_offer(pid, sdp_map) do
    GenServer.call(pid, {:process_offer, sdp_map})
  end

  @doc "Process a browser SDP answer (for server-initiated renegotiation)."
  def process_answer(pid, sdp_map) do
    GenServer.cast(pid, {:process_answer, sdp_map})
  end

  @doc "Add a browser ICE candidate."
  def add_ice_candidate(pid, candidate_map) do
    GenServer.cast(pid, {:add_ice_candidate, candidate_map})
  end

  @doc "Add a sendonly audio track for another participant; triggers renegotiation."
  def add_sender(pid, user_id) do
    GenServer.cast(pid, {:add_sender, user_id})
  end

  @doc "Stop forwarding RTP for a departed participant."
  def remove_sender(pid, user_id) do
    GenServer.cast(pid, {:remove_sender, user_id})
  end

  @doc "Forward an RTP packet from another participant to this peer's browser."
  def forward_rtp(pid, from_user_id, packet) do
    GenServer.cast(pid, {:forward_rtp, from_user_id, packet})
  end

  @doc "Update the LiveView PID after a page refresh."
  def set_lv_pid(pid, lv_pid) do
    GenServer.cast(pid, {:set_lv_pid, lv_pid})
  end

  # ── Server Callbacks ───────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Trap EXIT signals so that PeerConnection/DTLSTransport crashes during terminate/2
    # arrive as messages rather than killing this process mid-cleanup.
    Process.flag(:trap_exit, true)

    user_id = Keyword.fetch!(opts, :user_id)
    room_pid = Keyword.fetch!(opts, :room_pid)
    lv_pid = Keyword.fetch!(opts, :lv_pid)
    ice_servers = Keyword.get(opts, :ice_servers, @default_ice_servers)
    connect_timeout = Keyword.get(opts, :connect_timeout, @connect_timeout)

    Logger.info("Voice.Peer starting for user=#{user_id}")

    {:ok, pc} = PeerConnection.start_link(ice_servers: ice_servers)

    {:ok, %{
      user_id: user_id,
      room_pid: room_pid,
      lv_pid: lv_pid,
      pc: pc,
      mic_track_id: nil,
      senders: %{},            # %{user_id => track_id}
      negotiating: false,      # true while server-initiated offer is in-flight
      ready: false,            # true after initial browser offer processed
      pending_negotiate: false, # true if add_sender fired before ready
      connected: false,        # true once the connection has come up
      connect_timeout: connect_timeout,
      connect_timer: nil
    }}
  end

  @impl true
  def handle_call({:process_offer, %{"sdp" => sdp}}, _from, state) do
    offer = %SessionDescription{type: :offer, sdp: sdp}

    with :ok <- PeerConnection.set_remote_description(state.pc, offer),
         {:ok, answer} <- PeerConnection.create_answer(state.pc),
         :ok <- PeerConnection.set_local_description(state.pc, answer) do
      send(state.lv_pid, {:voice_signal, :answer, %{type: Atom.to_string(answer.type), sdp: answer.sdp}})
      new_state = %{state | ready: true, pending_negotiate: false} |> start_connect_timer()
      # If add_sender fired before we were ready, kick off the deferred renegotiation now
      if state.pending_negotiate, do: send(self(), :do_renegotiate)
      {:reply, :ok, new_state}
    else
      {:error, reason} ->
        Logger.error("Voice.Peer #{state.user_id}: failed to process offer: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:process_answer, %{"sdp" => sdp}}, state) do
    answer = %SessionDescription{type: :answer, sdp: sdp}

    case PeerConnection.set_remote_description(state.pc, answer) do
      :ok ->
        new_state = %{state | negotiating: false, pending_negotiate: false}
        # If add_sender fired while negotiation was in-flight, send now
        if state.pending_negotiate, do: send(self(), :do_renegotiate)
        {:noreply, new_state}
      {:error, reason} ->
        Logger.error("Voice.Peer #{state.user_id}: failed to process answer: #{inspect(reason)}")
        {:noreply, %{state | negotiating: false}}
    end
  end

  @impl true
  def handle_cast({:add_ice_candidate, map}, state) do
    candidate = %ICECandidate{
      candidate: map["candidate"],
      sdp_mid: map["sdpMid"],
      sdp_m_line_index: map["sdpMLineIndex"]
    }

    case PeerConnection.add_ice_candidate(state.pc, candidate) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("Voice.Peer #{state.user_id}: bad ICE candidate: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:add_sender, user_id}, state) do
    track = MediaStreamTrack.new(:audio)

    case PeerConnection.add_track(state.pc, track) do
      {:ok, _sender} ->
        {:noreply, %{state | senders: Map.put(state.senders, user_id, track.id)}}
      {:error, reason} ->
        Logger.error("Voice.Peer #{state.user_id}: add_track for #{user_id} failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:remove_sender, user_id}, state) do
    # Stop forwarding RTP for this user; track becomes silent
    {:noreply, %{state | senders: Map.delete(state.senders, user_id)}}
  end

  @impl true
  def handle_cast({:forward_rtp, from_user_id, packet}, state) do
    case Map.get(state.senders, from_user_id) do
      nil -> :ok
      track_id -> PeerConnection.send_rtp(state.pc, track_id, packet, [])
    end
    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_lv_pid, lv_pid}, state) do
    {:noreply, %{state | lv_pid: lv_pid}}
  end

  # ── PeerConnection messages ─────────────────────────────────────────

  @impl true
  def handle_info({:ex_webrtc, pc, :negotiation_needed}, state) when pc == state.pc do
    cond do
      not state.ready ->
        # Initial browser offer not received yet — buffer; do_renegotiate will fire later
        {:noreply, %{state | pending_negotiate: true}}

      state.negotiating ->
        # One offer already in-flight; buffer — do_renegotiate will fire when answer arrives
        {:noreply, %{state | pending_negotiate: true}}

      true ->
        do_renegotiate(state)
    end
  end

  def handle_info(:do_renegotiate, state) do
    do_renegotiate(state)
  end

  def handle_info({:ex_webrtc, pc, {:ice_candidate, nil}}, state) when pc == state.pc do
    # End-of-candidates marker; nothing to send
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, state) when pc == state.pc do
    send(state.lv_pid, {:voice_signal, :ice_candidate, %{
      candidate: candidate.candidate,
      sdpMid: candidate.sdp_mid,
      sdpMLineIndex: candidate.sdp_m_line_index
    }})
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:track, track}}, state) when pc == state.pc do
    # Incoming remote track from the browser
    if track.kind == :audio do
      Logger.info("Voice.Peer #{state.user_id}: mic track ready (#{track.id})")
      {:noreply, %{state | mic_track_id: track.id}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:ex_webrtc, pc, {:rtp, track_id, _rid, packet}}, state) when pc == state.pc do
    if track_id == state.mic_track_id do
      GenServer.cast(state.room_pid, {:forward_rtp, state.user_id, packet})
    end
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :failed}}, state) when pc == state.pc do
    reason = if state.connected, do: :connection_lost, else: :connect_failed
    Logger.warning("Voice.Peer #{state.user_id}: connection failed (#{reason}), self-terminating")
    {:stop, {:shutdown, reason}, state}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, state) when pc == state.pc do
    Logger.info("Voice.Peer #{state.user_id}: connection → connected")
    if state.connect_timer, do: Process.cancel_timer(state.connect_timer)
    send(state.lv_pid, {:voice_connection, :connected})
    {:noreply, %{state | connected: true, connect_timer: nil}}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, conn_state}}, state) when pc == state.pc do
    Logger.info("Voice.Peer #{state.user_id}: connection → #{conn_state}")
    {:noreply, state}
  end

  def handle_info(:connect_timeout, %{connected: false} = state) do
    Logger.warning("Voice.Peer #{state.user_id}: no connection #{state.connect_timeout}ms after the offer")
    {:stop, {:shutdown, :connect_timeout}, state}
  end

  def handle_info(:connect_timeout, state), do: {:noreply, state}

  # init traps exits, so the PeerConnection dying arrives as a message. It used
  # to fall through to the catch-all below, leaving this Peer alive with no
  # connection — a participant nobody could hear, whom nothing would remove.
  def handle_info({:EXIT, pc, reason}, state) when pc == state.pc do
    Logger.warning("Voice.Peer #{state.user_id}: PeerConnection exited (#{inspect(reason)})")
    {:stop, {:shutdown, :peer_connection_down}, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────

  # Once, from the first offer. A renegotiation doesn't restart the clock.
  defp start_connect_timer(%{connect_timer: nil, connected: false} = state) do
    %{state | connect_timer: Process.send_after(self(), :connect_timeout, state.connect_timeout)}
  end

  defp start_connect_timer(state), do: state

  defp do_renegotiate(state) do
    case PeerConnection.create_offer(state.pc) do
      {:ok, offer} ->
        :ok = PeerConnection.set_local_description(state.pc, offer)
        send(state.lv_pid, {:voice_signal, :offer, %{type: Atom.to_string(offer.type), sdp: offer.sdp}})
        {:noreply, %{state | negotiating: true, pending_negotiate: false}}
      {:error, reason} ->
        Logger.error("Voice.Peer #{state.user_id}: create_offer failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Voice.Peer #{state.user_id} terminating: #{inspect(reason)}")
    # Wrapped in try/catch: ex_webrtc 0.15.0 crashes in DTLSTransport.do_close when
    # dtls state is nil (connection never established — ICE/DTLS incomplete).
    # The linked PeerConnection will be killed by :shutdown propagation regardless.
    try do
      PeerConnection.close(state.pc)
    catch
      _, _ -> :ok
    end
    :ok
  end
end
