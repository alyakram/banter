defmodule Banter.Session do
  @moduledoc """
  GenServer that represents a single WebSocket session (Gateway connection).

  ## Responsibilities:
  - Manages session state (user, guilds, sequence numbers)
  - Handles IDENTIFY and RESUME flows
  - Implements heartbeat mechanism with timeouts
  - Dispatches events to the client via Phoenix Channel
  - Subscribes to relevant PubSub topics

  ## Session States:
  - :waiting_identify - Initial state, waiting for IDENTIFY
  - :identified - Client has identified, session is active
  - :zombie - Missed heartbeat, waiting for reconnect

  ## Heartbeat Mechanism:
  - Server expects heartbeat every N milliseconds
  - If client misses heartbeat, session becomes :zombie
  - Zombie sessions are cleaned up after timeout
  """

  use GenServer
  require Logger

  alias Banter.Gateway
  alias BanterWeb.Presence
  alias Banter.Accounts

  @heartbeat_interval 45_000  # 45 seconds
  @heartbeat_timeout 60_000   # 60 seconds (allow some grace period)
  @zombie_timeout 180_000     # 3 minutes before cleaning up zombie session

  defmodule State do
    @moduledoc false
    defstruct [
      :session_id,
      :user_id,
      :channel_pid,
      :state,
      :sequence,
      :last_heartbeat_at,
      :heartbeat_timer,
      :zombie_timer,
      :guild_subscriptions
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            user_id: String.t() | nil,
            channel_pid: pid(),
            state: :waiting_identify | :identified | :zombie,
            sequence: non_neg_integer(),
            last_heartbeat_at: integer() | nil,
            heartbeat_timer: reference() | nil,
            zombie_timer: reference() | nil,
            guild_subscriptions: MapSet.t()
          }
  end

  # Client API

  @doc """
  Starts a session process.
  """
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    channel_pid = Keyword.fetch!(opts, :channel_pid)

    GenServer.start_link(
      __MODULE__,
      %{session_id: session_id, channel_pid: channel_pid},
      name: via_tuple(session_id)
    )
  end

  @doc """
  Handles IDENTIFY payload from client.
  """
  def identify(session_id, user_id, guild_ids \\ []) do
    GenServer.call(via_tuple(session_id), {:identify, user_id, guild_ids})
  end

  @doc """
  Handles RESUME payload from client.
  """
  def resume(session_id, user_id, sequence) do
    GenServer.call(via_tuple(session_id), {:resume, user_id, sequence})
  end

  @doc """
  Handles HEARTBEAT from client.
  """
  def heartbeat(session_id) do
    GenServer.cast(via_tuple(session_id), :heartbeat)
  end

  @doc """
  Dispatches an event to the session.
  """
  def dispatch_event(session_id, event_name, data) do
    GenServer.cast(via_tuple(session_id), {:dispatch_event, event_name, data})
  end

  # Server Callbacks

  @impl true
  def init(%{session_id: session_id, channel_pid: channel_pid}) do
    Logger.info("🚀 Starting Session for session_id=#{session_id}")

    # Send HELLO to client
    send_payload(channel_pid, Gateway.hello_payload(@heartbeat_interval))
    Logger.info("Session #{session_id} sent HELLO (heartbeat_interval: #{@heartbeat_interval}ms)")

    # Start heartbeat timeout timer
    heartbeat_timer = schedule_heartbeat_check()
    Logger.debug("Session #{session_id} scheduled first heartbeat check in #{@heartbeat_interval}ms")

    state = %State{
      session_id: session_id,
      channel_pid: channel_pid,
      state: :waiting_identify,
      sequence: 0,
      last_heartbeat_at: System.monotonic_time(:millisecond),
      heartbeat_timer: heartbeat_timer,
      guild_subscriptions: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:identify, user_id, guild_ids}, _from, state) do
    if state.state == :waiting_identify do
      Logger.info("Session #{state.session_id} identified as user_id=#{user_id}")

      # Get user's availability status
      user_status = get_user_availability(user_id)

      # Track user presence
      {:ok, _} = Presence.track(
        state.channel_pid,
        "users:online",
        user_id,
        %{
          online_at: System.system_time(:second),
          status: user_status,
          session_id: state.session_id
        }
      )

      Logger.debug("Tracking presence for user #{user_id} with status #{user_status}")

      # Subscribe to guilds
      new_subscriptions =
        Enum.reduce(guild_ids, state.guild_subscriptions, fn guild_id, acc ->
          Phoenix.PubSub.subscribe(Banter.PubSub, "guild:#{guild_id}")
          MapSet.put(acc, guild_id)
        end)

      # Send READY event
      ready_data = %{
        user_id: user_id,
        session_id: state.session_id,
        guilds: guild_ids
      }

      new_state = %{
        state |
        user_id: user_id,
        state: :identified,
        guild_subscriptions: new_subscriptions,
        sequence: state.sequence + 1
      }

      dispatch(new_state, Gateway.event_ready(), ready_data)

      {:reply, :ok, new_state}
    else
      {:reply, {:error, :already_identified}, state}
    end
  end

  @impl true
  def handle_call({:resume, user_id, sequence}, _from, state) do
    if state.state == :zombie && state.user_id == user_id do
      Logger.info("Session #{state.session_id} resumed for user_id=#{user_id}")

      # Cancel zombie timer
      if state.zombie_timer, do: Process.cancel_timer(state.zombie_timer)

      # Send RESUMED event
      new_state = %{state | state: :identified, zombie_timer: nil}
      dispatch(new_state, Gateway.event_resumed(), %{})

      {:reply, {:ok, sequence}, new_state}
    else
      # Invalid resume attempt
      send_payload(state.channel_pid, Gateway.invalid_session_payload(false))
      {:reply, {:error, :invalid_session}, state}
    end
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    if state.state in [:identified, :zombie] do
      now = System.monotonic_time(:millisecond)
      time_since_last = now - (state.last_heartbeat_at || now)

      Logger.debug(
        "Session #{state.session_id} received HEARTBEAT " <>
        "(state: #{state.state}, #{time_since_last}ms since last)"
      )

      # Update last heartbeat time
      new_state = %{state | last_heartbeat_at: now}

      # If zombie, transition back to identified
      new_state =
        if state.state == :zombie do
          Logger.info("✓ Session #{state.session_id} recovered from zombie state via heartbeat")
          if state.zombie_timer, do: Process.cancel_timer(state.zombie_timer)
          %{new_state | state: :identified, zombie_timer: nil}
        else
          new_state
        end

      # Send heartbeat ACK
      send_payload(state.channel_pid, Gateway.heartbeat_ack_payload())
      Logger.debug("Session #{state.session_id} sent HEARTBEAT_ACK")

      {:noreply, new_state}
    else
      Logger.warning("Session #{state.session_id} received heartbeat but not in correct state: #{state.state}")
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:dispatch_event, event_name, data}, state) do
    if state.state == :identified do
      dispatch(state, event_name, data)
      {:noreply, %{state | sequence: state.sequence + 1}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check_heartbeat, state) do
    now = System.monotonic_time(:millisecond)
    time_since_heartbeat = now - (state.last_heartbeat_at || now)

    Logger.debug(
      "Session #{state.session_id} heartbeat check " <>
      "(state: #{state.state}, #{time_since_heartbeat}ms since last, timeout: #{@heartbeat_timeout}ms)"
    )

    new_state =
      if time_since_heartbeat > @heartbeat_timeout && state.state == :identified do
        Logger.warning(
          "⚠ Session #{state.session_id} missed heartbeat " <>
          "(#{time_since_heartbeat}ms > #{@heartbeat_timeout}ms), entering ZOMBIE state"
        )

        # Transition to zombie state
        zombie_timer = schedule_zombie_cleanup()
        %{state | state: :zombie, zombie_timer: zombie_timer}
      else
        if state.state == :identified do
          Logger.debug("Session #{state.session_id} heartbeat check OK (#{time_since_heartbeat}ms < #{@heartbeat_timeout}ms)")
        end
        state
      end

    # Schedule next heartbeat check
    heartbeat_timer = schedule_heartbeat_check()
    new_state = %{new_state | heartbeat_timer: heartbeat_timer}

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:zombie_cleanup, state) do
    if state.state == :zombie do
      Logger.warning("💀 Cleaning up zombie session #{state.session_id} (#{@zombie_timeout}ms timeout expired)")
      {:stop, :normal, state}
    else
      Logger.debug("Zombie cleanup timer fired but session #{state.session_id} is no longer zombie")
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:guild_event, event}, state) do
    # Forward guild events to client if session is identified
    if state.state == :identified do
      case event do
        {:message_create, message} ->
          dispatch(state, Gateway.event_message_create(), serialize_message(message))

        {:channel_create, channel} ->
          dispatch(state, Gateway.event_channel_create(), serialize_channel(channel))

        {:member_join, member} ->
          dispatch(state, Gateway.event_guild_member_add(), serialize_member(member))

        _ ->
          :ok
      end

      {:noreply, %{state | sequence: state.sequence + 1}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("Session #{state.session_id} terminating: #{inspect(reason)}")

    # Untrack user presence
    if state.user_id do
      Presence.untrack(state.channel_pid, "users:online", state.user_id)
      Logger.debug("Untracked presence for user #{state.user_id}")
    end

    # Unsubscribe from all guilds
    Enum.each(state.guild_subscriptions, fn guild_id ->
      Phoenix.PubSub.unsubscribe(Banter.PubSub, "guild:#{guild_id}")
    end)

    :ok
  end

  # Private Helpers

  defp via_tuple(session_id) do
    {:via, Registry, {Banter.SessionRegistry, session_id}}
  end

  defp dispatch(state, event_name, data) do
    payload = Gateway.dispatch_event(event_name, data, state.sequence)
    send_payload(state.channel_pid, payload)
  end

  defp send_payload(channel_pid, payload) do
    send(channel_pid, {:push_event, payload})
  end

  defp schedule_heartbeat_check do
    Process.send_after(self(), :check_heartbeat, @heartbeat_interval)
  end

  defp schedule_zombie_cleanup do
    Process.send_after(self(), :zombie_cleanup, @zombie_timeout)
  end

  # Serialization helpers

  defp serialize_message(message) do
    %{
      id: message.id,
      channel_id: message.channel_id,
      author_id: message.author_id,
      content: message.content,
      timestamp: message.inserted_at
    }
  end

  defp serialize_channel(channel) do
    %{
      id: channel.id,
      name: channel.name,
      server_id: channel.server_id
    }
  end

  defp serialize_member(member) do
    %{
      user_id: member.user_id,
      server_id: member.server_id,
      role: member.role
    }
  end

  defp get_user_availability(user_id) do
    case Ash.get(Banter.Accounts.User, user_id) do
      {:ok, user} -> user.availability || :online
      _ -> :online
    end
  end
end
