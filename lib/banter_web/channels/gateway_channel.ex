defmodule BanterWeb.GatewayChannel do
  @moduledoc """
  Phoenix Channel for Gateway WebSocket connections.

  Clients connect to this channel and receive a session ID.
  The channel interfaces with the Session GenServer to handle:
  - IDENTIFY
  - RESUME
  - HEARTBEAT
  - Event dispatching

  ## Connection Flow:
  1. Client connects to "gateway:connect"
  2. Server starts Session GenServer, sends HELLO with heartbeat_interval
  3. Client sends IDENTIFY with user_id and guilds
  4. Server sends READY event
  5. Client begins sending HEARTBEAT at intervals
  6. Server dispatches events (MESSAGE_CREATE, etc.)
  """

  use Phoenix.Channel
  require Logger

  alias Banter.{Session, Gateway}

  @impl true
  def join("gateway:connect", _params, socket) do
    # Generate a unique session ID using UUID v7
    session_id = "session_#{Ash.UUID.generate()}"

    # Start session GenServer
    case DynamicSupervisor.start_child(
           Banter.SessionSupervisor,
           {Session, session_id: session_id, channel_pid: self()}
         ) do
      {:ok, _pid} ->
        Logger.info("Client connected to gateway, session_id=#{session_id}")

        socket =
          socket
          |> assign(:session_id, session_id)
          |> assign(:authenticated, false)

        {:ok, %{session_id: session_id}, socket}

      {:error, reason} ->
        Logger.error("Failed to start session: #{inspect(reason)}")
        {:error, %{reason: "failed to start session"}}
    end
  end

  @impl true
  def join(_channel, _params, _socket) do
    {:error, %{reason: "invalid channel"}}
  end

  @impl true
  def handle_in("message", %{"op" => op, "d" => data}, socket) do
    opcode = Gateway.int_to_opcode(op)
    Logger.debug("Gateway received opcode #{op} (#{opcode}) from session #{socket.assigns.session_id}")
    handle_opcode(opcode, data, socket)
  end

  @impl true
  def handle_in(_event, _payload, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:push_event, payload}, socket) do
    push(socket, "message", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(reason, _socket) do
    Logger.info("Client disconnected from gateway: #{inspect(reason)}")
    :ok
  end

  # Opcode Handlers

  defp handle_opcode(:identify, data, socket) do
    %{"user_id" => user_id, "guilds" => guild_ids} = data
    session_id = socket.assigns.session_id

    Logger.info("Gateway processing IDENTIFY for session #{session_id}, user_id=#{user_id}, guilds=#{inspect(guild_ids)}")

    case Session.identify(session_id, user_id, guild_ids) do
      :ok ->
        Logger.info("✓ Session #{session_id} successfully identified")
        socket = assign(socket, :authenticated, true)
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("✗ IDENTIFY failed for session #{session_id}: #{inspect(reason)}")
        {:reply, {:error, %{reason: "identify failed"}}, socket}
    end
  end

  defp handle_opcode(:resume, data, socket) do
    %{"user_id" => user_id, "seq" => sequence} = data
    session_id = socket.assigns.session_id

    case Session.resume(session_id, user_id, sequence) do
      {:ok, _seq} ->
        socket = assign(socket, :authenticated, true)
        {:noreply, socket}

      {:error, reason} ->
        Logger.error("RESUME failed: #{inspect(reason)}")
        {:reply, {:error, %{reason: "resume failed"}}, socket}
    end
  end

  defp handle_opcode(:heartbeat, _data, socket) do
    session_id = socket.assigns.session_id
    Logger.debug("Gateway forwarding HEARTBEAT to Session #{session_id}")
    Session.heartbeat(session_id)
    {:noreply, socket}
  end

  defp handle_opcode(:unknown, _data, socket) do
    Logger.warning("Received unknown opcode")
    {:noreply, socket}
  end

  defp handle_opcode(opcode, _data, socket) do
    Logger.warning("Unhandled opcode: #{opcode}")
    {:noreply, socket}
  end
end
