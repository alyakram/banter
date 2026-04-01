defmodule Banter.Gateway do
  @moduledoc """
  Gateway event types and opcodes for WebSocket communication.

  Inspired by Discord's Gateway API:
  - IDENTIFY: Initial handshake
  - RESUME: Reconnect with existing session
  - HEARTBEAT: Keep-alive ping
  - HEARTBEAT_ACK: Server acknowledges heartbeat
  - DISPATCH: Server dispatches an event to client
  """

  # Opcodes
  @opcode_dispatch 0
  @opcode_heartbeat 1
  @opcode_identify 2
  @opcode_resume 6
  @opcode_reconnect 7
  @opcode_invalid_session 9
  @opcode_hello 10
  @opcode_heartbeat_ack 11

  @type opcode ::
          :dispatch
          | :heartbeat
          | :identify
          | :resume
          | :reconnect
          | :invalid_session
          | :hello
          | :heartbeat_ack

  @doc """
  Converts opcode atom to integer.
  """
  def opcode_to_int(:dispatch), do: @opcode_dispatch
  def opcode_to_int(:heartbeat), do: @opcode_heartbeat
  def opcode_to_int(:identify), do: @opcode_identify
  def opcode_to_int(:resume), do: @opcode_resume
  def opcode_to_int(:reconnect), do: @opcode_reconnect
  def opcode_to_int(:invalid_session), do: @opcode_invalid_session
  def opcode_to_int(:hello), do: @opcode_hello
  def opcode_to_int(:heartbeat_ack), do: @opcode_heartbeat_ack

  @doc """
  Converts integer opcode to atom.
  """
  def int_to_opcode(@opcode_dispatch), do: :dispatch
  def int_to_opcode(@opcode_heartbeat), do: :heartbeat
  def int_to_opcode(@opcode_identify), do: :identify
  def int_to_opcode(@opcode_resume), do: :resume
  def int_to_opcode(@opcode_reconnect), do: :reconnect
  def int_to_opcode(@opcode_invalid_session), do: :invalid_session
  def int_to_opcode(@opcode_hello), do: :hello
  def int_to_opcode(@opcode_heartbeat_ack), do: :heartbeat_ack
  def int_to_opcode(_), do: :unknown

  @doc """
  Creates a gateway payload.

  ## Examples

      iex> Banter.Gateway.payload(:hello, %{heartbeat_interval: 45000})
      %{op: 10, d: %{heartbeat_interval: 45000}}

  """
  def payload(opcode, data, event_name \\ nil, sequence \\ nil) do
    %{
      op: opcode_to_int(opcode),
      d: data
    }
    |> maybe_add(:t, event_name)
    |> maybe_add(:s, sequence)
  end

  @doc """
  Creates a dispatch event payload.
  """
  def dispatch_event(event_name, data, sequence) do
    payload(:dispatch, data, event_name, sequence)
  end

  @doc """
  Creates a HELLO payload with heartbeat interval.
  """
  def hello_payload(heartbeat_interval \\ 45_000) do
    payload(:hello, %{heartbeat_interval: heartbeat_interval})
  end

  @doc """
  Creates a HEARTBEAT_ACK payload.
  """
  def heartbeat_ack_payload do
    payload(:heartbeat_ack, nil)
  end

  @doc """
  Creates an INVALID_SESSION payload.
  """
  def invalid_session_payload(resumable \\ false) do
    payload(:invalid_session, resumable)
  end

  @doc """
  Creates a RECONNECT payload.
  """
  def reconnect_payload do
    payload(:reconnect, nil)
  end

  # Event names for DISPATCH opcode
  @doc """
  Event name constants for dispatch events.
  """
  def event_ready, do: "READY"
  def event_resumed, do: "RESUMED"
  def event_message_create, do: "MESSAGE_CREATE"
  def event_message_update, do: "MESSAGE_UPDATE"
  def event_message_delete, do: "MESSAGE_DELETE"
  def event_channel_create, do: "CHANNEL_CREATE"
  def event_channel_update, do: "CHANNEL_UPDATE"
  def event_channel_delete, do: "CHANNEL_DELETE"
  def event_guild_create, do: "GUILD_CREATE"
  def event_guild_update, do: "GUILD_UPDATE"
  def event_guild_delete, do: "GUILD_DELETE"
  def event_guild_member_add, do: "GUILD_MEMBER_ADD"
  def event_guild_member_remove, do: "GUILD_MEMBER_REMOVE"
  def event_presence_update, do: "PRESENCE_UPDATE"

  # Private helpers

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)
end
