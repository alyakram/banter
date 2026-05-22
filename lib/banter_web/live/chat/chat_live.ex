defmodule BanterWeb.ChatLive do
  @moduledoc """
  Main chat interface — Discord-style 3-panel layout.

  Layout:
  ┌────┬──────────┬────────────────────────────┐
  │    │ #general  │  #general                  │
  │ 🟢 │ #random   │                            │
  │ 🔵 │ #voice    │  [messages scroll here]     │
  │    │           │                            │
  │    │           │                            │
  │    │           │ ┌────────────────────────┐ │
  │    │           │ │ Type a message...      │ │
  │    │           │ └────────────────────────┘ │
  └────┴──────────┴────────────────────────────┘
   servers channels        messages
  """

  use BanterWeb, :live_view

  alias Banter.{Chat, GuildServer, Voice}
  alias BanterWeb.Presence
  alias BanterWeb.ChatLive.Components
  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to presence updates and track user as online
    if connected?(socket) && socket.assigns[:current_user] do
      Phoenix.PubSub.subscribe(Banter.PubSub, "users:online")

      # Track current user as online
      user = socket.assigns.current_user

      {:ok, _} =
        Presence.track(
          self(),
          "users:online",
          user.id,
          %{
            online_at: System.system_time(:second),
            status: user.availability || :online,
            email: user.email
          }
        )
    end

    socket =
      socket
      |> assign(:servers, [])
      |> assign(:current_server, nil)
      |> assign(:channels, [])
      |> assign(:current_channel, nil)
      |> assign(:messages, [])
      |> assign(:members, [])
      |> assign(:message_input, "")
      |> assign(:show_create_server_modal, false)
      |> assign(:show_join_server_modal, false)
      |> assign(:invite_code_input, "")
      |> assign(:new_server_name, "")
      |> assign(:new_channel_name, "")
      |> assign(:show_create_channel_modal, false)
      |> assign(:page_title, "Banter")
      |> assign(:subscribed_guild_id, nil)
      |> assign(:messages_cursor, nil)
      |> assign(:has_more_messages, false)
      |> assign(:loading_more_messages, false)
      |> assign(:online_users, Presence.online_user_ids())
      |> assign(:show_status_menu, false)
      |> assign(:voice_states, %{})
      |> assign(:current_voice_channel, nil)
      |> assign(:voice_muted, false)
      |> assign(:voice_deafened, false)
      |> assign(:voice_peer_pid, nil)
      |> assign(:show_mobile_sidebar, false)
      |> allow_upload(:attachments,
        accept: ~w(.jpg .jpeg .png .gif .webp .svg),
        max_entries: 10,
        max_file_size: 25_000_000,  # 25 MB
        auto_upload: false
      )

    # Restore voice WebRTC on connected mount (handles page refresh)
    socket =
      if connected?(socket) && socket.assigns[:current_user] do
        case Chat.get_user_voice_state(socket.assigns.current_user.id) do
          {:ok, voice_state} when not is_nil(voice_state) ->
            {:ok, channel} = Chat.get_channel(voice_state.channel_id)

            socket
            |> assign(:current_voice_channel, channel)
            |> assign(:voice_muted, voice_state.self_mute)
            |> assign(:voice_deafened, voice_state.self_deaf)
            |> setup_voice_peer(voice_state.channel_id)

          _ ->
            socket
        end
      else
        socket
      end

    # Load user's servers if authenticated
    socket =
      if socket.assigns[:current_user] do
        load_user_servers(socket)
      else
        socket
      end

    {:ok, socket, layout: {BanterWeb.Layouts, :chat}}
  end

  @impl true
  def handle_params(%{"server_id" => server_id, "channel_id" => channel_id}, _uri, socket) do

    socket =
      socket
      |> load_server(server_id)
      |> load_channel(channel_id)
      |> subscribe_to_channel(channel_id)
      |> assign(:show_mobile_sidebar, false)

    {:noreply, socket}
  end

  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = load_server(socket, server_id)

    # Auto-select first channel
    case socket.assigns.channels do
      [first | _] ->
        socket =
          socket
          |> load_channel(first.id)
          |> subscribe_to_channel(first.id)

        {:noreply,
         push_patch(socket,
           to: ~p"/chat/#{server_id}/#{first.id}",
           replace: true
         )}

      [] ->
        {:noreply, socket}
    end
  end

  def handle_params(_params, _uri, socket) do
    # No server selected — show server list
    {:noreply, socket}
  end

  # ── Events ──────────────────────────────────────────────────────────

  def handle_event("toggle_join_server_modal", _, socket) do
    {:noreply, assign(socket, :show_join_server_modal, !socket.assigns.show_join_server_modal)}
  end

  def handle_event("join_server_by_invite", %{"invite_code" => code}, socket) do
    code = String.trim(code) |> String.upcase()

    with {:ok, server} <- Chat.get_server_by_invite(code),
         {:ok, _member} <- GuildServer.join_guild(server.id, socket.assigns.current_user.id) do
      # Find first channel to navigate to
      {:ok, channels} = Chat.list_server_channels(%{server_id: server.id})

      socket =
        socket
        |> assign(:show_join_server_modal, false)
        |> assign(:invite_code_input, "")
        |> load_user_servers()

      case channels do
        [first | _] -> {:noreply, push_patch(socket, to: ~p"/chat/#{server.id}/#{first.id}")}
        [] -> {:noreply, push_patch(socket, to: ~p"/chat/#{server.id}")}
      end
    else
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Invalid invite code or already a member")}
    end
  end

  @impl true
  def handle_event("send_message", %{"content" => content}, socket) do
    content = String.trim(content)
    has_content = content != ""
    has_uploads = length(socket.assigns.uploads.attachments.entries) > 0

    if (has_content || has_uploads) && socket.assigns.current_channel && socket.assigns.current_server do
      # Consume uploaded files
      attachment_data =
        consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
          server_id = socket.assigns.current_server.id
          channel_id = socket.assigns.current_channel.id

          # Upload to local filesystem
          case Banter.Storage.upload_file(
                 path,
                 server_id,
                 channel_id,
                 entry.client_name,
                 entry.client_type
               ) do
            {:ok, result} ->
              {:ok,
               %{
                 filename: entry.client_name,
                 size: entry.client_size,
                 content_type: entry.client_type,
                 storage_path: result.storage_path,
                 url: result.url
               }}

            {:error, _reason} ->
              {:postpone, :error}
          end
        end)

      # Send message with attachment data
      case GuildServer.send_message_with_attachments(
             socket.assigns.current_server.id,
             socket.assigns.current_channel.id,
             socket.assigns.current_user.id,
             content,
             attachment_data
           ) do
        {:ok, _message} ->
          {:noreply, assign(socket, :message_input, "")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to send message")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_server", %{"name" => name}, socket) do
    case Chat.create_server(%{
           name: name,
           owner_id: socket.assigns.current_user.id
         }) do
      {:ok, server} ->
        # Auto-create #general channel
        {:ok, channel} = Chat.create_channel(%{name: "general", server_id: server.id})

        # Auto-join as owner using GuildServer
        {:ok, _member} = GuildServer.join_guild(server.id, socket.assigns.current_user.id)

        socket =
          socket
          |> assign(:show_create_server_modal, false)
          |> assign(:new_server_name, "")
          |> load_user_servers()
          |> push_patch(to: ~p"/chat/#{server.id}/#{channel.id}")

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create server")}
    end
  end

  def handle_event("create_channel", %{"name" => name} = params, socket) do
    if socket.assigns.current_server do
      channel_name = name |> String.downcase() |> String.replace(~r/\s+/, "-")
      channel_type = String.to_existing_atom(params["type"] || "text")

      case GuildServer.create_channel(
             socket.assigns.current_server.id,
             socket.assigns.current_user.id,
             channel_name,
             type: channel_type
           ) do
        {:ok, channel} ->
          socket =
            socket
            |> assign(:show_create_channel_modal, false)
            |> assign(:new_channel_name, "")
            |> load_server(socket.assigns.current_server.id)
            |> push_patch(to: ~p"/chat/#{socket.assigns.current_server.id}/#{channel.id}")

          {:noreply, socket}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to create channel")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_create_server_modal", _, socket) do
    {:noreply, assign(socket, :show_create_server_modal, !socket.assigns.show_create_server_modal)}
  end

  def handle_event("toggle_create_channel_modal", _, socket) do
    {:noreply,
     assign(socket, :show_create_channel_modal, !socket.assigns.show_create_channel_modal)}
  end

  def handle_event("toggle_mobile_sidebar", _, socket) do
    {:noreply, assign(socket, :show_mobile_sidebar, !socket.assigns.show_mobile_sidebar)}
  end

  def handle_event("close_mobile_sidebar", _, socket) do
    {:noreply, assign(socket, :show_mobile_sidebar, false)}
  end

  def handle_event("select_server", %{"id" => server_id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/chat/#{server_id}")}
  end

  def handle_event("select_channel", %{"id" => channel_id}, socket) do
    server_id = socket.assigns.current_server.id
    {:noreply, push_patch(socket, to: ~p"/chat/#{server_id}/#{channel_id}")}
  end

  def handle_event("update_message_input", %{"content" => content}, socket) do
    {:noreply, assign(socket, :message_input, content)}
  end

  def handle_event("validate_message", _params, socket) do
    # This handler allows LiveView to track file uploads
    # File selection triggers automatic upload tracking
    require Logger
    Logger.info("Validate message called - Upload entries: #{length(socket.assigns.uploads.attachments.entries)}")
    {:noreply, socket}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  def handle_event("load_more_messages", _, socket) do
    if socket.assigns.has_more_messages &&
         !socket.assigns.loading_more_messages &&
         socket.assigns.current_channel do
      socket = assign(socket, :loading_more_messages, true)

      {:ok, msgs} =
        Chat.list_channel_messages(%{
          channel_id: socket.assigns.current_channel.id,
          before_id: socket.assigns.messages_cursor
        })

      has_more = length(msgs) > 50
      msgs = Enum.take(msgs, 50)
      new_cursor = if msgs != [], do: List.last(msgs).id, else: nil
      older_messages = Ash.load!(Enum.reverse(msgs), [:author, :attachments])

      socket =
        socket
        |> update(:messages, fn messages -> older_messages ++ messages end)
        |> assign(:messages_cursor, new_cursor || socket.assigns.messages_cursor)
        |> assign(:has_more_messages, has_more)
        |> assign(:loading_more_messages, false)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_status_menu", _, socket) do
    {:noreply, assign(socket, :show_status_menu, !socket.assigns.show_status_menu)}
  end

  def handle_event("change_status", %{"status" => status_str}, socket) do
    require Logger
    status = String.to_existing_atom(status_str)
    user = socket.assigns.current_user

    Logger.info("Changing status for user #{user.id} to #{status}")

    # Update database using Ash changeset with actor
    result =
      user
      |> Ash.Changeset.for_update(:update_availability, %{availability: status})
      |> Ash.update(actor: user)

    case result do
      {:ok, updated_user} ->
        Logger.info(
          "Successfully updated user status to #{status}, new availability: #{updated_user.availability}"
        )

        # Update Presence metadata
        Presence.update(self(), "users:online", user.id, fn meta ->
          Map.put(meta, :status, status)
        end)

        Logger.info("Updated presence for user #{user.id}")

        socket =
          socket
          |> assign(:current_user, updated_user)
          |> assign(:show_status_menu, false)

        {:noreply, socket}

      {:error, error} ->
        Logger.error("Failed to update status: #{inspect(error)}")
        {:noreply, put_flash(socket, :error, "Failed to update status")}
    end
  end

  # ── Voice Events ────────────────────────────────────────────────────

  def handle_event("join_voice_channel", %{"id" => channel_id}, socket) do
    user = socket.assigns.current_user
    server = socket.assigns.current_server

    # No-op if already in this voice channel
    if socket.assigns.current_voice_channel && socket.assigns.current_voice_channel.id == channel_id do
      {:noreply, socket}
    else
      if server do
        # Leave current voice channel first if in one
        maybe_leave_current_voice(socket)

        case Chat.join_voice_channel(%{
               user_id: user.id,
               channel_id: channel_id,
               server_id: server.id
             }) do
          {:ok, voice_state} ->
            voice_state = Ash.load!(voice_state, :user)

            Phoenix.PubSub.broadcast(
              Banter.PubSub,
              "guild:#{server.id}",
              {:guild_event, {:voice_state_update, %{action: :join, voice_state: voice_state}}}
            )

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to join voice channel")}
        end
      else
        {:noreply, socket}
      end
    end
  end

  def handle_event("leave_voice_channel", _, socket) do
    maybe_leave_current_voice(socket)
    {:noreply, socket}
  end

  def handle_event("toggle_voice_mute", _, socket) do
    new_muted = !socket.assigns.voice_muted

    case Chat.get_user_voice_state(socket.assigns.current_user.id) do
      {:ok, voice_state} when not is_nil(voice_state) ->
        case Chat.update_voice_state(voice_state, %{self_mute: new_muted}) do
          {:ok, updated_vs} ->
            updated_vs = Ash.load!(updated_vs, :user)

            Phoenix.PubSub.broadcast(
              Banter.PubSub,
              "guild:#{socket.assigns.current_server.id}",
              {:guild_event, {:voice_state_update, %{action: :update, voice_state: updated_vs}}}
            )

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update mute")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_voice_deafen", _, socket) do
    new_deafened = !socket.assigns.voice_deafened
    new_muted = if new_deafened, do: true, else: socket.assigns.voice_muted

    case Chat.get_user_voice_state(socket.assigns.current_user.id) do
      {:ok, voice_state} when not is_nil(voice_state) ->
        case Chat.update_voice_state(voice_state, %{self_deaf: new_deafened, self_mute: new_muted}) do
          {:ok, updated_vs} ->
            updated_vs = Ash.load!(updated_vs, :user)

            Phoenix.PubSub.broadcast(
              Banter.PubSub,
              "guild:#{socket.assigns.current_server.id}",
              {:guild_event, {:voice_state_update, %{action: :update, voice_state: updated_vs}}}
            )

            {:noreply, socket}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update deafen")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ── Voice WebRTC signaling (browser → server) ───────────────────────

  def handle_event("voice_offer", sdp_map, socket) do
    if peer_pid = socket.assigns[:voice_peer_pid] do
      Voice.Peer.process_offer(peer_pid, sdp_map)
    end

    {:noreply, socket}
  end

  def handle_event("voice_answer", sdp_map, socket) do
    if peer_pid = socket.assigns[:voice_peer_pid] do
      Voice.Peer.process_answer(peer_pid, sdp_map)
    end

    {:noreply, socket}
  end

  def handle_event("voice_ice_candidate", candidate_map, socket) do
    if peer_pid = socket.assigns[:voice_peer_pid] do
      Voice.Peer.add_ice_candidate(peer_pid, candidate_map)
    end

    {:noreply, socket}
  end

  # ── PubSub ──────────────────────────────────────────────────────────

  @impl true
  def handle_info({:guild_event, {:message_create, message}}, socket) do
    # Only add message if it's for the current channel
    if socket.assigns.current_channel && message.channel_id == socket.assigns.current_channel.id do
      # Load author and attachments for display
      {:ok, message} = Ash.load(message, [:author, :attachments])

      socket =
        socket
        |> update(:messages, fn messages -> messages ++ [message] end)

      {:noreply, push_event(socket, "scroll_to_bottom", %{})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:guild_event, {:channel_create, _channel}}, socket) do
    # Reload channels when a new channel is created
    if socket.assigns.current_server do
      {:noreply, load_server(socket, socket.assigns.current_server.id)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:guild_event, {:member_join, _member}}, socket) do
    # Reload members when someone joins
    if socket.assigns.current_server do
      case Chat.list_server_members(%{server_id: socket.assigns.current_server.id}) do
        {:ok, members} ->
          members = Ash.load!(members, :user)
          {:noreply, assign(socket, :members, members)}

        _ ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:guild_event, {:voice_state_update, %{action: action, voice_state: vs}}}, socket) do
    current_user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

    socket =
      case action do
        :join ->
          socket
          |> update(:voice_states, fn states ->
            Map.update(states, vs.channel_id, [vs], fn existing ->
              if Enum.any?(existing, &(&1.user_id == vs.user_id)) do
                Enum.map(existing, fn s -> if s.user_id == vs.user_id, do: vs, else: s end)
              else
                existing ++ [vs]
              end
            end)
          end)
          |> then(fn s ->
            if vs.user_id == current_user_id do
              channel = Enum.find(s.assigns.channels, &(&1.id == vs.channel_id))

              s
              |> assign(:current_voice_channel, channel)
              |> assign(:voice_muted, vs.self_mute)
              |> assign(:voice_deafened, vs.self_deaf)
              |> setup_voice_peer(vs.channel_id)
            else
              s
            end
          end)

        :leave ->
          socket
          |> update(:voice_states, fn states ->
            Map.new(states, fn {ch_id, users} ->
              {ch_id, Enum.reject(users, &(&1.user_id == vs.user_id))}
            end)
            |> Enum.reject(fn {_ch_id, users} -> users == [] end)
            |> Map.new()
          end)
          |> then(fn s ->
            if vs.user_id == current_user_id do
              s
              |> assign(:current_voice_channel, nil)
              |> assign(:voice_muted, false)
              |> assign(:voice_deafened, false)
              |> assign(:voice_peer_pid, nil)
            else
              s
            end
          end)

        :update ->
          socket
          |> update(:voice_states, fn states ->
            Map.update(states, vs.channel_id, [], fn users ->
              Enum.map(users, fn u -> if u.user_id == vs.user_id, do: vs, else: u end)
            end)
          end)
          |> then(fn s ->
            if vs.user_id == current_user_id do
              s
              |> assign(:voice_muted, vs.self_mute)
              |> assign(:voice_deafened, vs.self_deaf)
              |> push_event("voice_mute_changed", %{muted: vs.self_mute})
              |> push_event("voice_deafen_changed", %{deafened: vs.self_deaf})
            else
              s
            end
          end)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    # Update online users list when someone connects/disconnects
    {:noreply, assign(socket, :online_users, Presence.online_user_ids())}
  end

  # ── Voice WebRTC signaling (server → browser) ───────────────────────

  @impl true
  def handle_info({:voice_signal, :offer, sdp}, socket) do
    {:noreply, push_event(socket, "voice_offer", sdp)}
  end

  @impl true
  def handle_info({:voice_signal, :answer, sdp}, socket) do
    {:noreply, push_event(socket, "voice_answer", sdp)}
  end

  @impl true
  def handle_info({:voice_signal, :ice_candidate, candidate}, socket) do
    {:noreply, push_event(socket, "voice_ice_candidate", candidate)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # NOTE: We intentionally do NOT destroy VoiceState here.
    # On page refresh, terminate fires before the new LiveView mounts,
    # which would clear the user's voice state prematurely.
    # Stale voice states are cleaned up by VoiceCleanupWorker (Oban cron).

    # Untrack user from presence when they disconnect
    if socket.assigns[:current_user] do
      Presence.untrack(self(), "users:online", socket.assigns.current_user.id)
    end

    :ok
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp maybe_leave_current_voice(socket) do
    user = socket.assigns.current_user

    case Chat.get_user_voice_state(user.id) do
      {:ok, voice_state} when not is_nil(voice_state) ->
        voice_state_with_user = Ash.load!(voice_state, :user)
        Chat.leave_voice_channel(voice_state)

        # Leave the Voice.Room (tears down WebRTC pipeline for this user)
        Voice.Room.leave(voice_state.channel_id, user.id)

        Phoenix.PubSub.broadcast(
          Banter.PubSub,
          "guild:#{voice_state.server_id}",
          {:guild_event, {:voice_state_update, %{action: :leave, voice_state: voice_state_with_user}}}
        )

      _ ->
        :ok
    end
  end

  defp setup_voice_peer(socket, channel_id) do
    if connected?(socket) do
      user_id = socket.assigns.current_user.id

      case Voice.Room.join(channel_id, user_id, self()) do
        {:ok, peer_pid} ->
          socket
          |> assign(:voice_peer_pid, peer_pid)
          |> push_event("voice_mute_changed", %{muted: socket.assigns.voice_muted})
          |> push_event("voice_deafen_changed", %{deafened: socket.assigns.voice_deafened})

        {:error, reason} ->
          require Logger
          Logger.error("Failed to join Voice.Room: #{inspect(reason)}")
          socket
      end
    else
      socket
    end
  end

  defp load_user_servers(socket) do
    user = socket.assigns.current_user

    case Chat.list_user_memberships(%{user_id: user.id}) do
      {:ok, memberships} ->
        memberships = Ash.load!(memberships, :server)
        servers = Enum.map(memberships, & &1.server)
        assign(socket, :servers, servers)

      _ ->
        assign(socket, :servers, [])
    end
  end

  defp load_server(socket, server_id) do
    case Chat.get_server(server_id) do
      {:ok, server} ->
        {:ok, channels} = Chat.list_server_channels(%{server_id: server_id})
        {:ok, members} = Chat.list_server_members(%{server_id: server_id})
        members = Ash.load!(members, :user)

        # Load voice states grouped by channel (for display in channel list)
        voice_states_list = Chat.list_voice_states_for_server(server_id)
        voice_states_list = Ash.load!(voice_states_list, :user)
        voice_states_map = Enum.group_by(voice_states_list, & &1.channel_id)

        # NOTE: @current_voice_channel, @voice_muted, @voice_deafened are managed
        # in mount (restore on refresh) and PubSub handlers (join/leave/update).
        # They are NOT set here, so they persist across server switches.
        socket
        |> assign(:current_server, server)
        |> assign(:channels, channels)
        |> assign(:members, members)
        |> assign(:voice_states, voice_states_map)
        |> assign(:page_title, server.name)

      {:error, _} ->
        socket
        |> put_flash(:error, "Server not found")
        |> assign(:current_server, nil)
    end
  end

  defp load_channel(socket, channel_id) do
    case Chat.get_channel(channel_id) do
      {:ok, channel} ->
        {:ok, msgs} = Chat.list_channel_messages(%{channel_id: channel_id})

        has_more = length(msgs) > 50
        msgs = Enum.take(msgs, 50)
        cursor = if msgs != [], do: List.last(msgs).id, else: nil
        messages = Ash.load!(Enum.reverse(msgs), [:author, :attachments])

        socket
        |> assign(:current_channel, channel)
        |> assign(:messages, messages)
        |> assign(:messages_cursor, cursor)
        |> assign(:has_more_messages, has_more)
        |> assign(:loading_more_messages, false)

      {:error, _} ->
        socket
        |> assign(:current_channel, nil)
        |> assign(:messages, [])
        |> assign(:messages_cursor, nil)
        |> assign(:has_more_messages, false)
        |> assign(:loading_more_messages, false)
    end
  end

  defp subscribe_to_channel(socket, _channel_id) do
    server = socket.assigns.current_server
    already_subscribed = socket.assigns[:subscribed_guild_id]

    if connected?(socket) && server && server.id != already_subscribed do
      # Unsubscribe from previous guild if switching servers
      if already_subscribed do
        Phoenix.PubSub.unsubscribe(Banter.PubSub, "guild:#{already_subscribed}")
      end

      Phoenix.PubSub.subscribe(Banter.PubSub, "guild:#{server.id}")
      assign(socket, :subscribed_guild_id, server.id)
    else
      socket
    end
  end

  # ── Template ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-screen w-screen flex overflow-hidden bg-base-100 text-base-content font-['IBM_Plex_Sans',sans-serif]">
      <Components.server_rail servers={@servers} current_server={@current_server} />

      <%!-- Mobile backdrop — closes sidebar when tapped --%>
      <%= if @show_mobile_sidebar do %>
        <div class="fixed inset-0 bg-black/60 z-30 lg:hidden" phx-click="close_mobile_sidebar"></div>
      <% end %>

      <Components.channel_sidebar
        servers={@servers}
        current_server={@current_server}
        channels={@channels}
        current_channel={@current_channel}
        current_user={@current_user}
        show_status_menu={@show_status_menu}
        voice_states={@voice_states}
        current_voice_channel={@current_voice_channel}
        voice_muted={@voice_muted}
        voice_deafened={@voice_deafened}
        show_mobile_sidebar={@show_mobile_sidebar}
      />

      <Components.chat_area
        current_channel={@current_channel}
        messages={@messages}
        message_input={@message_input}
        online_users={@online_users}
        uploads={@uploads}
        has_more_messages={@has_more_messages}
        loading_more_messages={@loading_more_messages}
      />

      <Components.members_sidebar
        current_server={@current_server}
        members={@members}
        online_users={@online_users}
      />

      <%!-- Voice WebRTC (hidden, audio only) --%>
      <%!-- Mounted when user is in a voice channel — manages RTCPeerConnection lifecycle --%>
      <%= if @current_voice_channel do %>
        <div id="voice-channel" phx-hook="VoiceChannel" class="hidden"></div>
      <% end %>

      <Components.create_server_modal
        show={@show_create_server_modal}
        new_server_name={@new_server_name}
      />

      <Components.create_channel_modal
        show={@show_create_channel_modal}
        server_name={@current_server && @current_server.name}
        new_channel_name={@new_channel_name}
      />

      <Components.join_server_modal
        show={@show_join_server_modal}
        invite_code_input={@invite_code_input}
      />
    </div>
    """
  end
end
