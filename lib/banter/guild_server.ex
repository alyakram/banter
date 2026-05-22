defmodule Banter.GuildServer do
  @moduledoc """
  GenServer that represents a single guild (server).

  ## Responsibilities:
  - Serializes all writes to the guild (natural ordering)
  - Holds cached guild state (channels, members)
  - Dispatches events to PubSub
  - Provides backpressure per guild

  ## Why one process per guild?
  - Write serialization without distributed locks
  - Fault isolation (one guild crash doesn't affect others)
  - Backpressure (overloaded guild's mailbox grows)
  - Location transparency (can live on any node)
  """

  use GenServer
  require Logger

  alias Banter.Chat

  @idle_timeout :timer.minutes(30)

  # Client API

  @doc """
  Starts a guild server process.

  The process is registered in the GuildRegistry with the server_id as key.
  """
  def start_link(server_id) do
    GenServer.start_link(__MODULE__, server_id, name: via_tuple(server_id))
  end

  @doc """
  Ensures a guild server is started for the given server_id.

  Returns `{:ok, pid}` if the process was started or already running.
  """
  def ensure_started(server_id) do
    case Registry.lookup(Banter.GuildRegistry, server_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(
          Banter.GuildSupervisor,
          {__MODULE__, server_id}
        )
    end
  end

  @doc """
  Sends a message to a channel in the guild.

  This serializes through the guild process, ensuring message ordering.
  """
  def send_message(server_id, channel_id, user_id, content, opts \\ []) do
    with {:ok, _pid} <- ensure_started(server_id) do
      GenServer.call(via_tuple(server_id), {:send_message, channel_id, user_id, content, opts})
    end
  end

  @doc """
  Sends a message with attachments to a channel in the guild.

  This serializes through the guild process, ensuring message ordering.
  """
  def send_message_with_attachments(server_id, channel_id, user_id, content, attachment_data \\ [], opts \\ []) do
    with {:ok, _pid} <- ensure_started(server_id) do
      GenServer.call(
        via_tuple(server_id),
        {:send_message_with_attachments, channel_id, user_id, content, attachment_data, opts}
      )
    end
  end

  @doc """
  Adds a member to the guild.
  """
  def join_guild(server_id, user_id) do
    with {:ok, _pid} <- ensure_started(server_id) do
      GenServer.call(via_tuple(server_id), {:join_guild, user_id})
    end
  end

  @doc """
  Gets the current guild state (cached in the process).
  """
  def get_state(server_id) do
    case Registry.lookup(Banter.GuildRegistry, server_id) do
      [{_pid, _}] ->
        GenServer.call(via_tuple(server_id), :get_state)

      [] ->
        {:error, :guild_not_started}
    end
  end

  @doc """
  Edits a message in the guild. The actor must be the message author.
  """
  def edit_message(server_id, message_id, new_content, actor) do
    with {:ok, _pid} <- ensure_started(server_id) do
      GenServer.call(via_tuple(server_id), {:edit_message, message_id, new_content, actor})
    end
  end

  @doc """
  Deletes a message in the guild. The actor must be the message author.
  """
  def delete_message(server_id, message_id, actor) do
    with {:ok, _pid} <- ensure_started(server_id) do
      GenServer.call(via_tuple(server_id), {:delete_message, message_id, actor})
    end
  end

  @doc """
  Creates a new channel in the guild.
  """
  def create_channel(server_id, user_id, name, opts \\ []) do
    with {:ok, _pid} <- ensure_started(server_id) do
      GenServer.call(via_tuple(server_id), {:create_channel, user_id, name, opts})
    end
  end

  # Server Callbacks

  @impl true
  def init(server_id) do
    Logger.info("Starting GuildServer for server_id=#{server_id}")

    case load_guild_state(server_id) do
      {:ok, state} ->
        # Subscribe to PubSub for this guild
        Phoenix.PubSub.subscribe(Banter.PubSub, "guild:#{server_id}")

        Logger.info("✓ GuildServer initialized: #{state.channel_ids |> length()} channels, #{state.member_ids |> length()} members")

        {:ok, state, @idle_timeout}

      {:error, reason} ->
        Logger.error("Failed to load guild state: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_message, channel_id, user_id, content, opts}, _from, state) do
    Logger.info("GuildServer received send_message: channel=#{channel_id}, user=#{user_id}")

    with {:ok, _channel} <- validate_channel(channel_id, state),
         {:ok, _member} <- validate_member(user_id, state) do
      Logger.debug("Validation passed, creating message...")

      reply_to_id = Keyword.get(opts, :reply_to_id)
      message_type = if reply_to_id, do: :reply, else: :default

      # Create message in database
      result =
        Chat.create_message(%{
          channel_id: channel_id,
          author_id: user_id,
          content: content,
          reply_to_id: reply_to_id,
          message_type: message_type
        }, authorize?: false)

      case result do
        {:ok, message} ->
          Logger.info("✓ Message created successfully: #{message.id}")

          # Broadcast event to all subscribers
          broadcast_event(state.server_id, {:message_create, message})

          {:reply, {:ok, message}, state, @idle_timeout}

        {:error, error} ->
          Logger.error("✗ Failed to create message: #{inspect(error)}")
          {:reply, {:error, error}, state, @idle_timeout}
      end
    else
      {:error, reason} ->
        Logger.warning("✗ Validation failed: #{inspect(reason)}")
        Logger.debug("State: channels=#{inspect(state.channel_ids)}, members=#{inspect(state.member_ids)}")
        {:reply, {:error, reason}, state, @idle_timeout}
    end
  end

  @impl true
  def handle_call({:send_message_with_attachments, channel_id, user_id, content, attachment_data, opts}, _from, state) do
    Logger.info("GuildServer received send_message with #{length(attachment_data)} attachments")

    with {:ok, _channel} <- validate_channel(channel_id, state),
         {:ok, _member} <- validate_member(user_id, state) do
      reply_to_id = Keyword.get(opts, :reply_to_id)
      message_type = if reply_to_id, do: :reply, else: :default

      # Create message with attachments
      result =
        Chat.create_message(%{
          channel_id: channel_id,
          author_id: user_id,
          content: content,
          attachments: attachment_data,
          reply_to_id: reply_to_id,
          message_type: message_type
        }, authorize?: false)

      case result do
        {:ok, message} ->
          # Load attachments and reply_to for broadcast
          message = Ash.load!(message, [:attachments, reply_to: [:author]])

          Logger.info("✓ Message created with #{length(message.attachments)} attachments")

          # Broadcast event to all subscribers
          broadcast_event(state.server_id, {:message_create, message})

          {:reply, {:ok, message}, state, @idle_timeout}

        {:error, error} ->
          Logger.error("✗ Failed to create message: #{inspect(error)}")
          {:reply, {:error, error}, state, @idle_timeout}
      end
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state, @idle_timeout}
    end
  end

  @impl true
  def handle_call({:join_guild, user_id}, _from, state) do
    result =
      Chat.join_server(%{
        server_id: state.server_id,
        user_id: user_id
      })

    case result do
      {:ok, member} ->
        # Update cached member list
        new_state = %{state | member_ids: [user_id | state.member_ids]}

        # Broadcast member join event
        broadcast_event(state.server_id, {:member_join, member})

        {:reply, {:ok, member}, new_state, @idle_timeout}

      {:error, error} ->
        {:reply, {:error, error}, state, @idle_timeout}
    end
  end

  @impl true
  def handle_call({:create_channel, user_id, name, opts}, _from, state) do
    with {:ok, _member} <- validate_member(user_id, state) do
      channel_type = Keyword.get(opts, :type, :text)

      result =
        Chat.create_channel(%{
          server_id: state.server_id,
          name: name,
          type: channel_type
        })

      case result do
        {:ok, channel} ->
          # Update cached channel list
          new_state = %{state | channel_ids: [channel.id | state.channel_ids]}

          # Broadcast channel create event
          broadcast_event(state.server_id, {:channel_create, channel})

          {:reply, {:ok, channel}, new_state, @idle_timeout}

        {:error, error} ->
          {:reply, {:error, error}, state, @idle_timeout}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state, @idle_timeout}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state, @idle_timeout}
  end

  @impl true
  def handle_call({:edit_message, message_id, new_content, actor}, _from, state) do
    with {:ok, message} <- Chat.get_message(message_id, authorize?: false),
         {:ok, updated} <- Chat.edit_message(message, %{content: new_content}, actor: actor) do
      updated = Ash.load!(updated, [:author, :attachments, reply_to: [:author]])
      broadcast_event(state.server_id, {:message_update, updated})
      {:reply, {:ok, updated}, state, @idle_timeout}
    else
      {:error, error} ->
        {:reply, {:error, error}, state, @idle_timeout}
    end
  end

  @impl true
  def handle_call({:delete_message, message_id, actor}, _from, state) do
    case Chat.get_message(message_id, authorize?: false) do
      {:ok, message} ->
        case Chat.delete_message(message, actor: actor) do
          result when result == :ok or (is_tuple(result) and elem(result, 0) == :ok) ->
            broadcast_event(state.server_id, {:message_delete, message_id})
            {:reply, :ok, state, @idle_timeout}

          {:error, error} ->
            {:reply, {:error, error}, state, @idle_timeout}
        end

      {:error, error} ->
        {:reply, {:error, error}, state, @idle_timeout}
    end
  end

  @impl true
  def handle_info(:timeout, state) do
    Logger.info("GuildServer for server_id=#{state.server_id} idle, shutting down")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state, @idle_timeout}
  end

  # Private Helpers

  defp via_tuple(server_id) do
    {:via, Registry, {Banter.GuildRegistry, server_id}}
  end

  defp load_guild_state(server_id) do
    with {:ok, server} <- Chat.get_server(server_id) do
      Logger.debug("Loading guild state for #{server.name}...")

      try do
        # Load channels and members for this guild
        channels = Chat.list_channels_for_server(server_id)
        Logger.debug("Loaded #{length(channels)} channels")

        members = Chat.list_members_for_server(server_id)
        Logger.debug("Loaded #{length(members)} members")

        state = %{
          server_id: server_id,
          server_name: server.name,
          channel_ids: Enum.map(channels, & &1.id),
          member_ids: Enum.map(members, & &1.user_id),
          owner_id: server.owner_id
        }

        {:ok, state}
      rescue
        error ->
          Logger.error("Error loading guild state: #{inspect(error)}")
          Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
          {:error, :load_failed}
      end
    else
      {:error, reason} ->
        Logger.error("Failed to get server: #{inspect(reason)}")
        {:error, reason}

      other ->
        Logger.error("Unexpected result from get_server: #{inspect(other)}")
        {:error, :unexpected_result}
    end
  end

  defp validate_channel(channel_id, state) do
    if channel_id in state.channel_ids do
      {:ok, channel_id}
    else
      {:error, :channel_not_found}
    end
  end

  defp validate_member(user_id, state) do
    if user_id in state.member_ids do
      {:ok, user_id}
    else
      {:error, :not_a_member}
    end
  end

  defp broadcast_event(server_id, event) do
    Phoenix.PubSub.broadcast(
      Banter.PubSub,
      "guild:#{server_id}",
      {:guild_event, event}
    )
  end
end
