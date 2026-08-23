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
  3. Client sends IDENTIFY with a signed auth token and requested guilds
  4. Server verifies the token, sends READY event with the guilds the user
     actually belongs to
  5. Client begins sending HEARTBEAT at intervals
  6. Server dispatches events (MESSAGE_CREATE, etc.)
  """

  use Phoenix.Channel
  require Logger

  alias Banter.{Session, Gateway}

  # IDENTIFY/RESUME share one rate-limit bucket per IP — the actual named
  # attack vector in AUDIT_FINDINGS.md #5 (mass session churn via scripted
  # auth attempts). Sharing the bucket between both opcodes prevents doubling
  # the effective budget by alternating between them.
  @auth_attempt_scope :gateway_auth_attempt
  @auth_attempt_limit 20
  @auth_attempt_window_ms 60_000
  @max_violations 3

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
          |> assign(:rate_limit_violations, 0)

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
    case check_auth_rate(socket) do
      :ok ->
        %{"token" => token, "guilds" => guild_ids} = data
        session_id = socket.assigns.session_id

        Logger.info("Gateway processing IDENTIFY for session #{session_id}")

        case Session.identify(session_id, token, guild_ids) do
          :ok ->
            Logger.info("✓ Session #{session_id} successfully identified")
            socket = assign(socket, :authenticated, true)
            {:noreply, socket}

          {:error, reason} ->
            Logger.warning("✗ IDENTIFY failed for session #{session_id}: #{inspect(reason)}")
            {:reply, {:error, %{reason: "identify failed"}}, socket}
        end

      {:limited, result} ->
        result
    end
  end

  defp handle_opcode(:resume, data, socket) do
    case check_auth_rate(socket) do
      :ok ->
        %{"token" => token, "seq" => sequence} = data
        session_id = socket.assigns.session_id

        case Session.resume(session_id, token, sequence) do
          {:ok, _seq} ->
            socket = assign(socket, :authenticated, true)
            {:noreply, socket}

          {:error, reason} ->
            Logger.warning("RESUME failed for session #{session_id}: #{inspect(reason)}")
            {:reply, {:error, %{reason: "resume failed"}}, socket}
        end

      {:limited, result} ->
        result
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

  # Checks the shared IDENTIFY/RESUME rate-limit bucket. Returns `:ok` to
  # proceed, or `{:limited, result}` where `result` is the tuple to return
  # directly from handle_opcode — a reply on the first couple of violations,
  # escalating to closing the connection after @max_violations.
  defp check_auth_rate(socket) do
    # socket.assigns[:client_ip] is always set by UserSocket.connect/3 in
    # production, but the fallback avoids a hard KeyError crash if a socket
    # ever reaches here without going through that path (e.g. a test helper
    # that constructs a channel socket directly).
    ip = socket.assigns[:client_ip] || "unknown"

    case Banter.RateLimiter.check_rate(
           @auth_attempt_scope,
           ip,
           @auth_attempt_limit,
           @auth_attempt_window_ms
         ) do
      :ok ->
        :ok

      {:error, :rate_limited} ->
        violations = socket.assigns.rate_limit_violations + 1
        socket = assign(socket, :rate_limit_violations, violations)

        if violations >= @max_violations do
          Logger.warning(
            "Session #{socket.assigns.session_id} exceeded rate-limit violations from #{ip}, closing"
          )

          {:limited, {:stop, {:shutdown, :rate_limited}, socket}}
        else
          Logger.warning("Session #{socket.assigns.session_id} rate-limited (attempt #{violations} from #{ip})")
          {:limited, {:reply, {:error, %{reason: "rate_limited"}}, socket}}
        end
    end
  end
end
