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
  alias BanterWeb.ChatLive.{Components, Feed}
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
            # No :status here on purpose — presence tracks connections, and a
            # user has one of these per tab plus one per gateway session.
            # Availability comes from the user record.
            online_at: System.system_time(:second),
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
      |> Feed.init()
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
      |> assign(:loading_more_messages, false)
      |> assign(:connected_users, Presence.connected_user_ids())
      |> assign(:show_status_menu, false)
      |> assign(:voice_states, %{})
      |> assign(:current_voice_channel, nil)
      |> assign(:voice_muted, false)
      |> assign(:voice_deafened, false)
      |> assign(:voice_peer_pid, nil)
      |> assign(:show_mobile_sidebar, false)
      |> assign(:editing_message_id, nil)
      |> assign(:editing_content, "")
      |> assign(:confirming_delete_id, nil)
      |> assign(:selected_message_id, nil)
      |> assign(:replying_to, nil)
      |> assign(:typing_users, %{})
      |> assign(:show_avatar_picker, false)
      |> allow_upload(:attachments,
        # No .svg — it's XML that can carry <script>, and uploads are served
        # same-origin from /uploads (AUDIT_FINDINGS.md #8).
        accept: ~w(.jpg .jpeg .png .gif .webp),
        max_entries: 10,
        max_file_size: 25_000_000,  # 25 MB
        auto_upload: false
      )

    # Restore voice WebRTC on connected mount (handles page refresh)
    socket =
      if connected?(socket) && socket.assigns[:current_user] do
        user = socket.assigns.current_user

        case Chat.get_user_voice_state(user.id, actor: user) do
          {:ok, voice_state} when not is_nil(voice_state) ->
            {:ok, channel} = Chat.get_channel(voice_state.channel_id, actor: user)

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
    socket = load_server(socket, server_id)

    if socket.assigns.current_server do
      socket =
        socket
        |> load_channel(channel_id)
        |> subscribe_to_channel(channel_id)
        |> assign(:show_mobile_sidebar, false)

      {:noreply, socket}
    else
      # Not found, or not a member — don't leave the user parked on a dead
      # URL with an empty shell; bounce back to the server list.
      {:noreply, push_patch(socket, to: ~p"/chat")}
    end
  end

  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = load_server(socket, server_id)

    if socket.assigns.current_server do
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
    else
      {:noreply, push_patch(socket, to: ~p"/chat")}
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
    user = socket.assigns.current_user

    with {:ok, server} <- Chat.get_server_by_invite(code),
         {:ok, _member} <- GuildServer.join_guild(server.id, user.id, user) do
      # Find first channel to navigate to
      {:ok, channels} = Chat.list_server_channels(%{server_id: server.id}, actor: user)

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
      results =
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
               {:uploaded,
                %{
                  filename: entry.client_name,
                  size: entry.client_size,
                  # The type Storage detected from the file's bytes, not
                  # entry.client_type — the browser's claim isn't authoritative,
                  # and the record should say what the file actually is.
                  content_type: result.content_type,
                  storage_path: result.storage_path,
                  url: result.url
                }}}

            # Rejected for what it *is* — retrying uploads the same bytes and
            # fails identically. Consume it (`{:ok, _}` clears the entry) so it
            # doesn't sit in the composer forever, and tell the user why.
            {:error, reason} when reason in [:unsupported_content_type, :content_type_mismatch] ->
              {:ok, {:rejected, entry.client_name}}

            # Something environmental — a failed copy, say. Keep the entry so
            # the next send can retry it.
            {:error, _reason} ->
              {:postpone, {:failed, entry.client_name}}
          end
        end)

      attachment_data = for {:uploaded, attachment} <- results, do: attachment
      rejected = for {:rejected, name} <- results, do: name

      socket =
        if rejected == [] do
          socket
        else
          put_flash(
            socket,
            :error,
            "Couldn't attach #{Enum.join(rejected, ", ")} — the file isn't a supported image."
          )
        end

      reply_to_id = socket.assigns.replying_to && socket.assigns.replying_to.id

      if content == "" and attachment_data == [] do
        # Nothing survived to post: the only attachments were rejected and
        # there was no text. Sending would fail the "content or attachments"
        # validation and replace the specific rejection flash above with a
        # generic "Failed to send message".
        {:noreply, socket}
      else
        # Send message with attachment data
        case GuildServer.send_message_with_attachments(
               socket.assigns.current_server.id,
               socket.assigns.current_channel.id,
               socket.assigns.current_user.id,
               content,
               attachment_data,
               reply_to_id: reply_to_id
             ) do
          {:ok, _message} ->
            {:noreply, socket |> assign(:message_input, "") |> assign(:replying_to, nil)}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to send message")}
        end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_server", %{"name" => name}, socket) do
    user = socket.assigns.current_user

    case Chat.create_server(%{name: name, owner_id: user.id}, actor: user) do
      {:ok, server} ->
        # Auto-create #general channel *before* GuildServer.join_guild below.
        # GuildServer.join_guild lazily starts the guild process and caches
        # its channel list at that moment — if it started first, the channel
        # created here wouldn't be in that cache and message sends would
        # silently fail. Bypasses Channel's policy: the actor just created
        # this server, so isn't a member yet, but is unquestionably trusted
        # to bootstrap its first channel.
        {:ok, channel} =
          Chat.create_channel(%{name: "general", server_id: server.id}, authorize?: false)

        {:ok, _member} = GuildServer.join_guild(server.id, user.id, user)

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
    if content != "" && socket.assigns.current_channel && socket.assigns.current_server do
      user = socket.assigns.current_user
      name = user.email |> to_string() |> String.split("@") |> List.first()

      Phoenix.PubSub.broadcast(
        Banter.PubSub,
        "guild:#{socket.assigns.current_server.id}",
        {:guild_event, {:typing, user.id, name, socket.assigns.current_channel.id}}
      )
    end

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
      socket =
        socket
        |> assign(:loading_more_messages, true)
        |> Feed.load_older()
        |> assign(:loading_more_messages, false)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # The MessageFeed hook, near the bottom of a detached feed.
  def handle_event("load_newer_messages", _, socket) do
    if socket.assigns.has_newer_messages && socket.assigns.current_channel do
      {:noreply, Feed.load_newer(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("jump_to_present", _, socket) do
    if socket.assigns.current_channel do
      {:noreply,
       socket
       |> Feed.load_latest(socket.assigns.current_channel.id)
       |> push_event("scroll_to_present", %{})}
    else
      {:noreply, socket}
    end
  end

  # From the FeedEnd hook, whenever the reader moves onto or off the
  # bottom of the feed. Trimming old messages only happens while they're on
  # it, so history someone has scrolled up to read is never pulled away.
  def handle_event("feed_at_bottom", %{"at_bottom" => at_bottom}, socket)
      when is_boolean(at_bottom) do
    {:noreply, assign(socket, :feed_at_bottom, at_bottom)}
  end

  def handle_event("toggle_status_menu", _, socket) do
    {:noreply, assign(socket, :show_status_menu, !socket.assigns.show_status_menu)}
  end

  def handle_event("toggle_avatar_picker", _, socket) do
    {:noreply, assign(socket, :show_avatar_picker, !socket.assigns.show_avatar_picker)}
  end

  def handle_event("select_avatar", %{"url" => url}, socket) do
    user = socket.assigns.current_user

    case user
         |> Ash.Changeset.for_update(:update_avatar, %{avatar_url: url})
         |> Ash.update(actor: user) do
      {:ok, updated_user} ->
        Phoenix.PubSub.broadcast(
          Banter.PubSub,
          "users:online",
          {:user_avatar_updated, user.id, url}
        )

        {:noreply,
         socket
         |> assign(:current_user, updated_user)
         |> assign(:show_avatar_picker, false)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update avatar")}
    end
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

        # Announce it rather than editing this tab's presence meta. Everyone is
        # already subscribed to "users:online", and each viewer holds the
        # user's availability on the record it already has — including this
        # user's *other* tabs, whose own footer would otherwise stay stale.
        # Same shape as the {:user_avatar_updated, ...} broadcast above.
        Phoenix.PubSub.broadcast(
          Banter.PubSub,
          "users:online",
          {:user_status_updated, user.id, status}
        )

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

  # ── Edit / Delete Events ────────────────────────────────────────────

  def handle_event("select_message", %{"id" => id}, socket) do
    new_id = if socket.assigns.selected_message_id == id, do: nil, else: id

    {:noreply, put_message_ui(socket, selected_message_id: new_id, confirming_delete_id: nil)}
  end

  def handle_event("deselect_message", _, socket) do
    {:noreply, put_message_ui(socket, selected_message_id: nil)}
  end

  def handle_event("start_edit", %{"id" => msg_id}, socket) do
    user_id = socket.assigns.current_user.id

    case fetch_channel_message(socket, msg_id) do
      {:ok, %{author_id: ^user_id} = message} ->
        {:noreply,
         socket
         # Before the redraw, so the form opens holding the current text.
         |> assign(:editing_content, message.content || "")
         |> put_message_ui(editing_message_id: msg_id, selected_message_id: nil)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("update_edit", params, socket) do
    # No redraw: the browser already shows what's being typed. Kept so a
    # redraw for some other reason (an avatar change, say) doesn't reset the
    # draft to the original text.
    {:noreply, assign(socket, :editing_content, params["content"] || "")}
  end

  def handle_event("save_edit", %{"message_id" => msg_id, "content" => content}, socket) do
    content = String.trim(content)

    if content == "" do
      {:noreply, socket}
    else
      case GuildServer.edit_message(
             socket.assigns.current_server.id,
             msg_id,
             content,
             socket.assigns.current_user
           ) do
        {:ok, _} ->
          # Only the assigns: the {:message_update, _} broadcast redraws the
          # message, and by then editing_message_id is already cleared.
          {:noreply, socket |> assign(:editing_message_id, nil) |> assign(:editing_content, "")}

        {:error, %Ash.Error.Forbidden{}} ->
          {:noreply, put_flash(socket, :error, "Not authorized to edit this message")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to edit message")}
      end
    end
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply,
     socket
     |> assign(:editing_content, "")
     |> put_message_ui(editing_message_id: nil)}
  end

  def handle_event("confirm_delete", %{"id" => msg_id}, socket) do
    {:noreply, put_message_ui(socket, confirming_delete_id: msg_id, selected_message_id: nil)}
  end

  def handle_event("cancel_delete", _, socket) do
    {:noreply, put_message_ui(socket, confirming_delete_id: nil)}
  end

  def handle_event("delete_message", %{"id" => msg_id}, socket) do
    case GuildServer.delete_message(
           socket.assigns.current_server.id,
           msg_id,
           socket.assigns.current_user
         ) do
      :ok ->
        # The {:message_delete, _} broadcast removes it from the feed.
        {:noreply, assign(socket, :confirming_delete_id, nil)}

      {:error, %Ash.Error.Forbidden{}} ->
        {:noreply,
         socket
         |> put_message_ui(confirming_delete_id: nil)
         |> put_flash(:error, "Not authorized to delete this message")}

      {:error, _} ->
        {:noreply,
         socket
         |> put_message_ui(confirming_delete_id: nil)
         |> put_flash(:error, "Failed to delete message")}
    end
  end

  # ── Reply Events ────────────────────────────────────────────────────

  def handle_event("start_reply", %{"id" => msg_id}, socket) do
    case fetch_channel_message(socket, msg_id) do
      {:ok, message} ->
        {:noreply,
         socket
         |> assign(:replying_to, message)
         |> put_message_ui(editing_message_id: nil, selected_message_id: nil)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_reply", _, socket) do
    {:noreply, assign(socket, :replying_to, nil)}
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

        case Chat.join_voice_channel(
               %{
                 user_id: user.id,
                 channel_id: channel_id,
                 server_id: server.id
               },
               actor: user
             ) do
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
    user = socket.assigns.current_user

    case Chat.get_user_voice_state(user.id, actor: user) do
      {:ok, voice_state} when not is_nil(voice_state) ->
        case Chat.update_voice_state(voice_state, %{self_mute: new_muted}, actor: user) do
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
    user = socket.assigns.current_user

    case Chat.get_user_voice_state(user.id, actor: user) do
      {:ok, voice_state} when not is_nil(voice_state) ->
        case Chat.update_voice_state(voice_state, %{self_deaf: new_deafened, self_mute: new_muted}, actor: user) do
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
      # Appended, trimmed around, or held below a detached feed — depending on
      # where the reader is.
      {:noreply, Feed.live_message(socket, message)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:guild_event, {:message_update, message}}, socket) do
    if socket.assigns.current_channel && message.channel_id == socket.assigns.current_channel.id do
      # Redraws it only if it's on screen — an edit to a message further back
      # than the loaded page must not be appended to the bottom.
      {:noreply, Feed.replace(socket, message)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:guild_event, {:message_delete, message_id}}, socket) do
    # Deletes arrive for every channel in the guild; Feed ignores ids it
    # hasn't rendered.
    {:noreply, Feed.delete(socket, message_id)}
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
      case Chat.list_server_members(%{server_id: socket.assigns.current_server.id},
             actor: socket.assigns.current_user
           ) do
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
    # Who is connected changed. Availability isn't touched here — it lives on
    # the user records this view already holds.
    {:noreply, assign(socket, :connected_users, Presence.connected_user_ids())}
  end

  @impl true
  def handle_info({:user_status_updated, user_id, status}, socket) do
    socket =
      socket
      |> update(:members, fn members ->
        Enum.map(members, fn member ->
          if member.user_id == user_id && member.user do
            %{member | user: %{member.user | availability: status}}
          else
            member
          end
        end)
      end)

    # If that was us, this is one of our own other tabs: the footer renders
    # @current_user.availability, so without this it would keep showing the
    # old status until remount.
    socket =
      if socket.assigns[:current_user] && socket.assigns.current_user.id == user_id do
        assign(socket, :current_user, %{socket.assigns.current_user | availability: status})
      else
        socket
      end

    {:noreply, socket}
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
  def handle_info({:user_avatar_updated, user_id, url}, socket) do
    socket =
      socket
      # Re-read rather than patched in place: the feed holds no message
      # structs, and the re-read already carries the new avatar.
      |> Feed.rerender_user(user_id)
      |> update(:members, fn members ->
        Enum.map(members, fn member ->
          if member.user_id == user_id && member.user do
            %{member | user: %{member.user | avatar_url: url}}
          else
            member
          end
        end)
      end)
      |> update(:voice_states, fn states ->
        Map.new(states, fn {ch_id, users} ->
          patched =
            Enum.map(users, fn vs ->
              if vs.user_id == user_id && vs.user do
                %{vs | user: %{vs.user | avatar_url: url}}
              else
                vs
              end
            end)

          {ch_id, patched}
        end)
      end)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:guild_event, {:typing, user_id, name, channel_id}}, socket) do
    current_user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

    if user_id != current_user_id &&
         socket.assigns.current_channel &&
         socket.assigns.current_channel.id == channel_id do
      Process.send_after(self(), {:clear_typing, user_id}, 3000)
      {:noreply, update(socket, :typing_users, &Map.put(&1, user_id, name))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:clear_typing, user_id}, socket) do
    {:noreply, update(socket, :typing_users, &Map.delete(&1, user_id))}
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

    case Chat.get_user_voice_state(user.id, actor: user) do
      {:ok, voice_state} when not is_nil(voice_state) ->
        voice_state_with_user = Ash.load!(voice_state, :user)
        Chat.leave_voice_channel(voice_state, actor: user)

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

  # Sets per-message UI state — which message is selected, being edited, or
  # awaiting delete confirmation — and redraws the messages whose look it
  # changes: each key's old message and its new one. The feed is a stream, so
  # assigning alone would leave them drawn as they were.
  defp put_message_ui(socket, changes) do
    touched = for {key, new_id} <- changes, id <- [socket.assigns[key], new_id], do: id

    socket
    |> assign(changes)
    |> Feed.rerender(touched)
  end

  # Looks the message up by id instead of in what the feed has rendered, so the
  # view needn't hold messages in memory to act on one. The read is
  # membership-gated by the actor; the channel match keeps a crafted event
  # from replying to or editing a message in another channel of the server.
  defp fetch_channel_message(socket, message_id) do
    %{current_user: user, current_channel: channel} = socket.assigns

    with %{id: channel_id} <- channel,
         {:ok, %{channel_id: ^channel_id} = message} <-
           Chat.get_message(message_id, actor: user, load: [:author]) do
      {:ok, message}
    else
      _ -> :error
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

    case Chat.list_user_memberships(%{user_id: user.id}, actor: user) do
      {:ok, memberships} ->
        memberships = Ash.load!(memberships, :server, actor: user)
        servers = Enum.map(memberships, & &1.server)
        assign(socket, :servers, servers)

      _ ->
        assign(socket, :servers, [])
    end
  end

  defp load_server(socket, server_id) do
    user = socket.assigns.current_user

    case Chat.get_server(server_id, actor: user) do
      {:ok, server} ->
        {:ok, channels} = Chat.list_server_channels(%{server_id: server_id}, actor: user)
        {:ok, members} = Chat.list_server_members(%{server_id: server_id}, actor: user)
        members = Ash.load!(members, :user)

        # Load voice states grouped by channel (for display in channel list)
        voice_states_list = Chat.list_voice_states_for_server(server_id, actor: user)
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
    case Chat.get_channel(channel_id, actor: socket.assigns.current_user) do
      {:ok, channel} ->
        socket
        |> assign(:current_channel, channel)
        |> Feed.load_latest(channel_id)
        |> assign(:loading_more_messages, false)
        |> assign(:typing_users, %{})

      {:error, _} ->
        socket
        |> assign(:current_channel, nil)
        |> Feed.reset([])
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
        show_avatar_picker={@show_avatar_picker}
        voice_states={@voice_states}
        current_voice_channel={@current_voice_channel}
        voice_muted={@voice_muted}
        voice_deafened={@voice_deafened}
        show_mobile_sidebar={@show_mobile_sidebar}
      />

      <Components.chat_area
        current_channel={@current_channel}
        messages={@streams.messages}
        message_input={@message_input}
        uploads={@uploads}
        can_moderate={!!(@current_server && @current_user && @current_server.owner_id == @current_user.id)}
        has_more_messages={@has_more_messages}
        has_newer_messages={@has_newer_messages}
        unseen_count={@unseen_count}
        loading_more_messages={@loading_more_messages}
        current_user={@current_user}
        editing_message_id={@editing_message_id}
        editing_content={@editing_content}
        confirming_delete_id={@confirming_delete_id}
        selected_message_id={@selected_message_id}
        replying_to={@replying_to}
        typing_users={@typing_users}
      />

      <Components.members_sidebar
        current_server={@current_server}
        members={@members}
        connected_users={@connected_users}
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
