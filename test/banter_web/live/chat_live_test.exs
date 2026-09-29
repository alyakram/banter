defmodule BanterWeb.ChatLiveTest do
  use BanterWeb.ConnCase

  import Phoenix.LiveViewTest
  import Banter.Fixtures

  alias Banter.Chat

  # A user with a server, a #general channel, and their owner membership —
  # the state the app puts you in right after creating a server.
  defp signed_in_with_server(conn) do
    user = user_fixture()
    {server, _} = server_with_owner_fixture(user)
    channel = channel_fixture(server, user, %{name: "general"})

    %{conn: log_in_user(conn, user), user: user, server: server, channel: channel}
  end

  describe "mount and access" do
    test "an anonymous visitor is sent to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/chat")
    end

    test "a signed-in user with no servers still mounts", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())

      assert {:ok, _view, html} = live(conn, ~p"/chat")
      assert html =~ "Banter" or html =~ "server"
    end

    test "a member landing on a server URL is redirected to its first channel", %{conn: conn} do
      %{conn: conn, server: server, channel: channel} = signed_in_with_server(conn)

      # The redirect happens inside the initial handle_params, so live/2
      # surfaces it as a live_redirect rather than mounting and patching.
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/chat/#{server.id}")
      assert to == "/chat/#{server.id}/#{channel.id}"
    end

    test "a member can open a channel URL directly", %{conn: conn} do
      %{conn: conn, server: server, channel: channel} = signed_in_with_server(conn)

      {:ok, _view, html} = live(conn, ~p"/chat/#{server.id}/#{channel.id}")

      assert html =~ "general"
    end
  end

  describe "access control on navigation" do
    # The membership redirect from AUDIT_FINDINGS.md #3. These are the tests
    # that would catch it regressing, since the resource-level policies only
    # guarantee the data is withheld — not that the UI does something sensible
    # about it.
    setup %{conn: conn} do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)
      channel = channel_fixture(server, owner, %{name: "general"})

      %{server: server, channel: channel, conn: log_in_user(conn, user_fixture())}
    end

    test "a non-member opening a server URL is bounced to the server list", %{
      conn: conn,
      server: server
    } do
      assert {:error, {:live_redirect, %{to: "/chat", flash: flash}}} =
               live(conn, ~p"/chat/#{server.id}")

      assert flash["error"] == "Server not found"
    end

    test "a non-member opening a channel URL is bounced to the server list", %{
      conn: conn,
      server: server,
      channel: channel
    } do
      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               live(conn, ~p"/chat/#{server.id}/#{channel.id}")
    end

    test "a nonexistent server id is bounced rather than rendering a dead shell", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/chat"}}} =
               live(conn, ~p"/chat/#{Ash.UUID.generate()}")
    end

    test "after the bounce the user sees the empty server list, not the server's channels", %{
      conn: conn,
      server: server,
      channel: channel
    } do
      {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/chat/#{server.id}/#{channel.id}")
      {:ok, _view, html} = live(conn, to)

      assert html =~ "Select or create a server"
      refute html =~ "# general"
    end
  end

  describe "creating a server" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    # The modal's markup only exists once it's open, so every test here has to
    # open it first — the same sequence a user performs.
    defp open_create_server_modal(view) do
      view |> element("nav button[phx-click='toggle_create_server_modal']") |> render_click()
      view
    end

    test "creates the server, its #general channel, and navigates there", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/chat")
      open_create_server_modal(view)

      view
      |> element("form[phx-submit='create_server']")
      |> render_submit(%{name: "My Server"})

      {:ok, servers} = Ash.read(Chat.Server, actor: user)
      assert [server] = servers
      assert server.name == "My Server"

      {:ok, channels} = Chat.list_server_channels(%{server_id: server.id}, actor: user)
      assert [%{name: "general"}] = channels

      assert_patch(view, ~p"/chat/#{server.id}/#{hd(channels).id}")
    end

    test "the creator is joined as a member", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      open_create_server_modal(view)

      view
      |> element("form[phx-submit='create_server']")
      |> render_submit(%{name: "Owned"})

      {:ok, [server]} = Ash.read(Chat.Server, actor: user)

      assert {:ok, [membership]} =
               Chat.list_server_members(%{server_id: server.id}, actor: user)

      assert membership.user_id == user.id
    end

    test "a too-short name is rejected without creating anything", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/chat")
      open_create_server_modal(view)

      html =
        view
        |> element("form[phx-submit='create_server']")
        |> render_submit(%{name: "x"})

      assert html =~ "Failed to create server"
      assert {:ok, []} = Ash.read(Chat.Server, actor: user)
    end

    test "the create-server modal toggles", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/chat")

      # "Create a server" also appears as a button title attribute, so assert
      # on copy that only exists inside the modal itself.
      refute render(view) =~ "Give your new server a personality"

      html = open_create_server_modal(view) |> render()
      assert html =~ "Give your new server a personality"
    end
  end

  describe "joining a server by invite" do
    setup %{conn: conn} do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)
      channel = channel_fixture(server, owner, %{name: "general"})
      joiner = user_fixture()

      %{conn: log_in_user(conn, joiner), joiner: joiner, server: server, channel: channel}
    end

    test "a valid invite code joins the server and navigates into it", %{
      conn: conn,
      joiner: joiner,
      server: server
    } do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view
      |> element("nav button[phx-click='toggle_join_server_modal']")
      |> render_click()

      view
      |> element("form[phx-submit='join_server_by_invite']")
      |> render_submit(%{invite_code: server.invite_code})

      assert {:ok, memberships} =
               Chat.list_user_memberships(%{user_id: joiner.id}, actor: joiner)

      assert server.id in Enum.map(memberships, & &1.server_id)
    end

    test "the invite code is matched case-insensitively", %{
      conn: conn,
      joiner: joiner,
      server: server
    } do
      # The handler upcases and trims before looking the code up.
      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element("nav button[phx-click='toggle_join_server_modal']") |> render_click()

      view
      |> element("form[phx-submit='join_server_by_invite']")
      |> render_submit(%{invite_code: "  " <> String.downcase(server.invite_code) <> " "})

      {:ok, memberships} = Chat.list_user_memberships(%{user_id: joiner.id}, actor: joiner)
      assert server.id in Enum.map(memberships, & &1.server_id)
    end

    test "an unknown invite code reports an error and joins nothing", %{
      conn: conn,
      joiner: joiner
    } do
      {:ok, view, _html} = live(conn, ~p"/chat")

      view |> element("nav button[phx-click='toggle_join_server_modal']") |> render_click()

      html =
        view
        |> element("form[phx-submit='join_server_by_invite']")
        |> render_submit(%{invite_code: "NOSUCH"})

      assert html =~ "Invalid invite code or already a member"
      assert {:ok, []} = Chat.list_user_memberships(%{user_id: joiner.id}, actor: joiner)
    end
  end

  describe "creating a channel" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")
      # Both the Text and Voice section headers render an identical toggle
      # button, so fire the event directly rather than trying to pick one.
      render_click(view, "toggle_create_channel_modal", %{})
      Map.put(ctx, :view, view)
    end

    test "creates a text channel in the current server", %{
      view: view,
      user: user,
      server: server
    } do
      view
      |> element("form[phx-submit='create_channel']")
      |> render_submit(%{name: "new-channel", type: "text"})

      {:ok, channels} = Chat.list_server_channels(%{server_id: server.id}, actor: user)
      assert "new-channel" in Enum.map(channels, & &1.name)
    end

    test "slugifies the name — spaces become hyphens and case is lowered", %{
      view: view,
      user: user,
      server: server
    } do
      view
      |> element("form[phx-submit='create_channel']")
      |> render_submit(%{name: "My Cool Channel", type: "text"})

      {:ok, channels} = Chat.list_server_channels(%{server_id: server.id}, actor: user)
      assert "my-cool-channel" in Enum.map(channels, & &1.name)
    end

    test "can create a voice channel", %{view: view, user: user, server: server} do
      view
      |> element("form[phx-submit='create_channel']")
      |> render_submit(%{name: "voice-room", type: "voice"})

      {:ok, channels} = Chat.list_server_channels(%{server_id: server.id}, actor: user)
      voice = Enum.find(channels, &(&1.name == "voice-room"))

      assert voice.type == :voice
    end
  end

  describe "sending messages" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")
      Map.put(ctx, :view, view)
    end

    test "a message is persisted and rendered", %{view: view, user: user, channel: channel} do
      view
      |> element("form[phx-submit='send_message']")
      |> render_submit(%{content: "hello world"})

      assert render(view) =~ "hello world"

      {:ok, messages} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      assert [%{content: "hello world"}] = messages
    end

    test "the message is attributed to the sender", %{view: view, user: user, channel: channel} do
      view
      |> element("form[phx-submit='send_message']")
      |> render_submit(%{content: "mine"})

      {:ok, [message]} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      assert message.author_id == user.id
    end

    test "an empty message is not persisted", %{view: view, user: user, channel: channel} do
      view
      |> element("form[phx-submit='send_message']")
      |> render_submit(%{content: "   "})

      assert {:ok, []} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
    end

    test "messages from other people arrive over PubSub", %{
      view: view,
      server: server,
      channel: channel
    } do
      other = user_fixture()
      member_fixture(other, server)

      {:ok, message} =
        Banter.GuildServer.send_message(server.id, channel.id, other.id, "from elsewhere")

      assert render(view) =~ "from elsewhere"
      assert message.author_id == other.id
    end

    test "a message for a different channel is ignored", %{
      view: view,
      user: user,
      server: server
    } do
      other_channel = channel_fixture(server, user, %{name: "other"})

      {:ok, _} =
        Banter.GuildServer.send_message(server.id, other_channel.id, user.id, "not here")

      refute render(view) =~ "not here"
    end
  end

  describe "editing and deleting messages" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")

      view
      |> element("form[phx-submit='send_message']")
      |> render_submit(%{content: "original text"})

      {:ok, [message]} =
        Chat.list_channel_messages(%{channel_id: ctx.channel.id}, actor: ctx.user)

      ctx |> Map.put(:view, view) |> Map.put(:message, message)
    end

    test "an author can edit their message", %{view: view, message: message, user: user} do
      view |> render_hook("start_edit", %{"id" => message.id})

      view |> render_hook("save_edit", %{"message_id" => message.id, "content" => "edited text"})

      {:ok, reloaded} = Chat.get_message(message.id, actor: user)
      assert reloaded.content == "edited text"

      # The handler deliberately changes no local assigns — the UI catches up
      # from the {:message_update, _} broadcast, so re-render rather than using
      # the html the event returned.
      html = render(view)
      assert html =~ "edited text"
      refute html =~ "original text"
    end

    test "cancelling an edit leaves the message alone", %{
      view: view,
      message: message,
      user: user
    } do
      view |> render_hook("start_edit", %{"id" => message.id})
      view |> render_hook("cancel_edit", %{})

      {:ok, reloaded} = Chat.get_message(message.id, actor: user)
      assert reloaded.content == "original text"
    end

    test "an author can delete their message", %{view: view, message: message, user: user} do
      view |> render_hook("delete_message", %{"id" => message.id})

      refute render(view) =~ "original text"
      assert {:ok, []} = Chat.list_channel_messages(%{channel_id: message.channel_id}, actor: user)
    end

    test "a deletion by someone else arrives over PubSub", %{
      view: view,
      server: server,
      message: message,
      user: user
    } do
      assert render(view) =~ "original text"

      :ok = Banter.GuildServer.delete_message(server.id, message.id, user)

      refute render(view) =~ "original text"
    end
  end

  describe "moderation controls in the UI" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      poster = user_fixture()
      member_fixture(poster, ctx.server)
      message = message_fixture(ctx.channel, poster, %{content: "someone else's words"})

      Map.merge(ctx, %{poster: poster, message: message})
    end

    test "the server owner sees a delete control on someone else's message", %{
      conn: conn,
      server: server,
      channel: channel,
      message: message
    } do
      {:ok, view, _} = live(conn, ~p"/chat/#{server.id}/#{channel.id}")

      html = render_click(view, "select_message", %{"id" => message.id})

      assert html =~ "confirm_delete"
    end

    test "but no edit control — moderating isn't rewriting", %{
      conn: conn,
      server: server,
      channel: channel,
      message: message
    } do
      {:ok, view, _} = live(conn, ~p"/chat/#{server.id}/#{channel.id}")

      html = render_click(view, "select_message", %{"id" => message.id})

      refute html =~ "start_edit"
    end

    test "and can actually delete it", %{
      conn: conn,
      user: owner,
      server: server,
      channel: channel,
      message: message
    } do
      {:ok, view, _} = live(conn, ~p"/chat/#{server.id}/#{channel.id}")

      render_hook(view, "delete_message", %{"id" => message.id})

      assert {:ok, []} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: owner)
    end

    test "hiding the edit control isn't the real boundary — a crafted edit is refused", %{
      conn: conn,
      server: server,
      channel: channel,
      message: message,
      user: owner
    } do
      # The UI omits Edit for a moderator, but that's cosmetic. Anyone can send
      # the event anyway, so the policy has to be what actually stops it.
      {:ok, view, _} = live(conn, ~p"/chat/#{server.id}/#{channel.id}")

      render_hook(view, "start_edit", %{"id" => message.id})
      render_hook(view, "save_edit", %{"message_id" => message.id, "content" => "forced"})

      {:ok, reloaded} = Chat.get_message(message.id, actor: owner)
      assert reloaded.content == "someone else's words"
      assert Process.alive?(view.pid)
    end

    test "an ordinary member sees no controls on someone else's message", %{
      conn: conn,
      server: server,
      channel: channel,
      message: message
    } do
      bystander = user_fixture()
      member_fixture(bystander, server)

      {:ok, view, _} =
        live(log_in_user(conn, bystander), ~p"/chat/#{server.id}/#{channel.id}")

      html = render_click(view, "select_message", %{"id" => message.id})

      refute html =~ "confirm_delete"
      refute html =~ "start_edit"
    end

    test "an author still sees both controls on their own message", %{
      conn: conn,
      poster: poster,
      server: server,
      channel: channel,
      message: message
    } do
      {:ok, view, _} = live(log_in_user(conn, poster), ~p"/chat/#{server.id}/#{channel.id}")

      html = render_click(view, "select_message", %{"id" => message.id})

      assert html =~ "confirm_delete"
      assert html =~ "start_edit"
    end
  end

  describe "status and avatar" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      {:ok, view, _html} = live(ctx.conn, ~p"/chat")
      Map.put(ctx, :view, view)
    end

    for status <- [:away, :dnd, :invisible, :online] do
      test "a user can set their status to #{status}", %{view: view, user: user} do
        view |> render_hook("change_status", %{"status" => to_string(unquote(status))})

        {:ok, reloaded} = Ash.get(Banter.Accounts.User, user.id, actor: user)
        assert reloaded.availability == unquote(status)
      end
    end

    test "a user can pick an avatar", %{view: view, user: user} do
      view |> render_hook("select_avatar", %{"url" => "/images/avatars/avatar-2.png"})

      {:ok, reloaded} = Ash.get(Banter.Accounts.User, user.id, actor: user)
      assert reloaded.avatar_url == "/images/avatars/avatar-2.png"
    end
  end

  describe "voice channels" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      voice = channel_fixture(ctx.server, ctx.user, %{name: "voice-room", type: :voice})
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")

      ctx |> Map.put(:view, view) |> Map.put(:voice, voice)
    end

    test "joining a voice channel records a voice state", %{
      view: view,
      voice: voice,
      user: user
    } do
      view |> render_hook("join_voice_channel", %{"id" => voice.id})

      assert {:ok, [state]} = Chat.list_voice_states_by_channel(voice.id, actor: user)
      assert state.user_id == user.id
    end

    test "leaving removes it again", %{view: view, voice: voice, user: user} do
      view |> render_hook("join_voice_channel", %{"id" => voice.id})
      view |> render_hook("leave_voice_channel", %{})

      assert {:ok, []} = Chat.list_voice_states_by_channel(voice.id, actor: user)
    end

    # Joins through the UI and returns the Peer the view ended up with — the
    # :join broadcast is what sets it up.
    defp join_voice(view, voice) do
      render_hook(view, "join_voice_channel", %{"id" => voice.id})
      render(view)
      peer = :sys.get_state(view.pid).socket.assigns.voice_peer_pid
      assert is_pid(peer)
      peer
    end

    defp peer_of(view), do: :sys.get_state(view.pid).socket.assigns.voice_peer_pid

    test "a lost connection takes the user out of voice, and everyone sees it", %{
      view: view,
      voice: voice,
      user: user,
      server: server,
      channel: channel
    } do
      peer = join_voice(view, voice)

      # Another member, watching the voice channel's list.
      other = user_fixture()
      member_fixture(other, server)

      {:ok, others_view, _} =
        live(log_in_user(build_conn(), other), ~p"/chat/#{server.id}/#{channel.id}")

      assert has_element?(others_view, ~s([data-voice-user="#{user.id}"]))

      GenServer.stop(peer, {:shutdown, :connection_lost})

      assert has_element?(view, "#flash-error", "Voice connection lost.")
      refute render(view) =~ "Voice Connected"
      assert {:ok, []} = Chat.list_voice_states_by_channel(voice.id, actor: user)

      # The ghost this fixes: they used to stay listed, with no audio, until
      # they closed the tab.
      refute has_element?(others_view, ~s([data-voice-user="#{user.id}"]))

      # And signaling no longer goes to a dead pid (#23).
      assert peer_of(view) == nil
    end

    test "a connection that never came up says so", %{view: view, voice: voice, user: user} do
      peer = join_voice(view, voice)

      GenServer.stop(peer, {:shutdown, :connect_timeout})

      assert has_element?(view, "#flash-error", "Couldn't connect to voice.")
      assert {:ok, []} = Chat.list_voice_states_by_channel(voice.id, actor: user)
    end

    test "a crashed Peer is treated as a lost connection", %{view: view, voice: voice, user: user} do
      peer = join_voice(view, voice)
      ref = Process.monitor(peer)

      # Unlike GenServer.stop, this returns before the Peer is gone.
      Process.exit(peer, :kill)
      assert_receive {:DOWN, ^ref, :process, ^peer, :killed}

      assert has_element?(view, "#flash-error", "Voice connection lost.")
      assert {:ok, []} = Chat.list_voice_states_by_channel(voice.id, actor: user)
    end

    test "another tab taking over voice leaves the voice state alone", %{
      conn: conn,
      view: view,
      voice: voice,
      user: user,
      server: server,
      channel: channel
    } do
      _peer = join_voice(view, voice)

      # A second tab restores voice on mount, which replaces this tab's Peer.
      {:ok, other_tab, _} = live(conn, ~p"/chat/#{server.id}/#{channel.id}")

      assert has_element?(view, "#flash-info", "Voice moved to another tab.")
      refute render(view) =~ "Voice Connected"
      assert render(other_tab) =~ "Voice Connected"
      assert {:ok, [state]} = Chat.list_voice_states_by_channel(voice.id, actor: user)
      assert state.user_id == user.id
    end

    test "leaving on purpose isn't reported as a loss", %{view: view, voice: voice} do
      _peer = join_voice(view, voice)

      render_hook(view, "leave_voice_channel", %{})

      refute has_element?(view, "#flash-error")
      refute render(view) =~ "Voice Connected"
    end

    test "switching voice channels isn't reported as a loss", %{
      view: view,
      voice: voice,
      user: user,
      server: server
    } do
      other_voice = channel_fixture(server, user, %{name: "other-voice", type: :voice})
      first = join_voice(view, voice)

      second = join_voice(view, other_voice)

      refute has_element?(view, "#flash-error")
      refute Process.alive?(first)
      assert Process.alive?(second)
      assert {:ok, [state]} = Chat.list_voice_states_by_channel(other_voice.id, actor: user)
      assert state.user_id == user.id
    end

    test "a denied microphone takes the user out, and says why", %{
      view: view,
      voice: voice,
      user: user
    } do
      _peer = join_voice(view, voice)

      render_hook(view, "voice_failed", %{"reason" => "NotAllowedError"})

      assert has_element?(view, "#flash-error", "Microphone access was denied.")
      assert {:ok, []} = Chat.list_voice_states_by_channel(voice.id, actor: user)
      refute render(view) =~ "Voice Connected"
    end

    test "a missing microphone gets its own message", %{view: view, voice: voice} do
      _peer = join_voice(view, voice)

      render_hook(view, "voice_failed", %{"reason" => "NotFoundError"})

      assert has_element?(view, "#flash-error", "No microphone was found.")
    end

    test "mute and deafen toggles are persisted", %{view: view, voice: voice, user: user} do
      view |> render_hook("join_voice_channel", %{"id" => voice.id})

      view |> render_hook("toggle_voice_mute", %{})
      {:ok, muted} = Chat.get_user_voice_state(user.id, actor: user)
      assert muted.self_mute == true

      view |> render_hook("toggle_voice_deafen", %{})
      {:ok, deafened} = Chat.get_user_voice_state(user.id, actor: user)
      assert deafened.self_deaf == true
    end
  end

  describe "navigating between servers and channels" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      second_channel = channel_fixture(ctx.server, ctx.user, %{name: "random"})
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")

      ctx |> Map.put(:view, view) |> Map.put(:second_channel, second_channel)
    end

    test "selecting a channel patches to its URL", %{
      view: view,
      server: server,
      second_channel: second
    } do
      render_click(view, "select_channel", %{"id" => second.id})

      assert_patch(view, ~p"/chat/#{server.id}/#{second.id}")
    end

    test "switching channels swaps the visible messages", %{
      view: view,
      user: user,
      channel: channel,
      second_channel: second
    } do
      message_fixture(channel, user, %{content: "in general"})
      message_fixture(second, user, %{content: "in random"})

      render_click(view, "select_channel", %{"id" => second.id})
      html = render(view)

      assert html =~ "in random"
      refute html =~ "in general"
    end

    test "selecting a server patches to that server", %{view: view, user: user} do
      {other_server, _} = server_with_owner_fixture(user)
      _other_channel = channel_fixture(other_server, user, %{name: "general"})

      render_click(view, "select_server", %{"id" => other_server.id})

      assert_patch(view)
    end

    test "load_server is safe to run repeatedly", %{
      conn: conn,
      server: server,
      channel: channel
    } do
      # Navigating away and back re-runs load_server/load_channel, which is
      # where a missing actor would surface as a suddenly-empty channel list.
      {:ok, view, _} = live(conn, ~p"/chat/#{server.id}/#{channel.id}")

      render_click(view, "select_channel", %{"id" => channel.id})
      html = render(view)

      assert html =~ "general"
    end
  end

  describe "loading older messages" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)

      # 60 messages: more than the 50 the view shows, so a second page exists.
      messages =
        for n <- 1..60 do
          message_fixture(ctx.channel, ctx.user, %{content: "message #{n}"})
        end

      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")
      ctx |> Map.put(:view, view) |> Map.put(:messages, messages)
    end

    test "the newest 50 are shown initially, not the oldest", %{view: view} do
      html = render(view)

      assert html =~ "message 60"
      refute html =~ "message 1<"
    end

    test "load_more_messages prepends the older page", %{view: view} do
      refute render(view) =~ "message 2<"

      render_click(view, "load_more_messages", %{})
      html = render(view)

      assert html =~ "message 1"
      assert html =~ "message 60"
    end

    test "the older page lands above, in order", %{view: view, messages: messages} do
      render_click(view, "load_more_messages", %{})

      # Positions of each message's element in the rendered page. Prepending a
      # list at the top of a stream reverses it unless done carefully.
      ids = Enum.map(messages, &"id=\"message-#{&1.id}\"")
      html = render(view)
      positions = Enum.map(ids, fn id -> :binary.match(html, id) |> elem(0) end)

      assert positions == Enum.sort(positions)
    end

    test "the message that was first joins the run above it once older ones load", %{
      view: view,
      messages: messages
    } do
      # All 60 are one author, seconds apart: one run. The 11th was first on
      # screen, so it had to carry the header; with the 10th above it, it
      # continues the run instead.
      eleventh = Enum.at(messages, 10)
      assert has_element?(view, "#message-#{eleventh.id}[data-layout=full]")

      render_click(view, "load_more_messages", %{})

      assert has_element?(view, "#message-#{eleventh.id}[data-layout=compact]")
    end

    test "an edit to a message that isn't on screen isn't added to it", %{
      view: view,
      server: server,
      user: user,
      messages: [first | _]
    } do
      {:ok, _} = Banter.GuildServer.edit_message(server.id, first.id, "edited far back", user)

      refute render(view) =~ "edited far back"
    end

    test "the view holds no message content, however much has loaded", %{view: view} do
      render_click(view, "load_more_messages", %{})
      assert render(view) =~ "message 42"

      # This is what the stream is for: before it, every loaded message sat
      # in the process's assigns for the life of the view.
      assigns = :sys.get_state(view.pid).socket.assigns

      refute Map.has_key?(assigns, :messages)
      assert length(assigns.rendered_messages) == 60
      refute inspect(assigns, limit: :infinity, printable_limit: :infinity) =~ "message 42"
    end
  end

  describe "trimming a long feed" do
    alias BanterWeb.ChatLive.Feed

    # Exactly trim_at messages, all paged in: the feed is full, and the next
    # live message is the one that tips it over.
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)

      messages =
        for n <- 1..Feed.trim_at() do
          message_fixture(ctx.channel, ctx.user, %{content: "message #{n}"})
        end

      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")
      page_in_everything(view)

      ctx |> Map.put(:view, view) |> Map.put(:messages, messages)
    end

    defp page_in_everything(view) do
      if has_element?(view, "#message-feed[data-has-more=true]") do
        render_click(view, "load_more_messages", %{})
        page_in_everything(view)
      end
    end

    # What the server thinks is on screen, and what actually is. They must
    # agree, or grouping and paging go wrong.
    defp rendered(view) do
      entries = :sys.get_state(view.pid).socket.assigns.rendered_messages
      on_page = Regex.scan(~r/id="message-[0-9a-f]{8}-/, render(view)) |> length()

      assert length(entries) == on_page
      on_page
    end

    defp post_live(ctx, content) do
      {:ok, message} =
        Banter.GuildServer.send_message(ctx.server.id, ctx.channel.id, ctx.user.id, content)

      message
    end

    test "paging in history is never trimmed", %{view: view} do
      assert rendered(view) == Feed.trim_at()
    end

    test "at the bottom, a message past the limit trims the oldest back to the window",
         %{view: view, messages: messages} = ctx do
      post_live(ctx, "one too many")

      assert rendered(view) == Feed.window()
      assert render(view) =~ "one too many"

      # Kept: the newest `window`, counting the one just posted.
      first_kept = Enum.at(messages, Feed.trim_at() + 1 - Feed.window())
      last_trimmed = Enum.at(messages, Feed.trim_at() - Feed.window())

      refute has_element?(view, "#message-#{last_trimmed.id}")
      # It was drawn compact mid-run; now it's first, so it carries the header.
      assert has_element?(view, "#message-#{first_kept.id}[data-layout=full]")
    end

    test "the trimmed messages load back when scrolling up",
         %{view: view, messages: messages} = ctx do
      post_live(ctx, "one too many")
      assert has_element?(view, "#message-feed[data-has-more=true]")

      render_click(view, "load_more_messages", %{})

      last_trimmed = Enum.at(messages, Feed.trim_at() - Feed.window())
      assert has_element?(view, "#message-#{last_trimmed.id}")
      assert rendered(view) == Feed.window() + 50
    end

    test "scrolled up with the feed full, a new message waits below instead",
         %{view: view} = ctx do
      render_hook(view, "feed_at_bottom", %{"at_bottom" => false})
      held = post_live(ctx, "while reading history")

      # Neither appended past the cap nor trimmed from the top, which could be
      # what's being read. The feed detaches and the bar says why.
      assert rendered(view) == Feed.trim_at()
      refute has_element?(view, "#message-#{held.id}")
      assert has_element?(view, "#message-feed[data-has-newer=true]")
      assert has_element?(view, "#jump-to-present", "1 new message")

      # Scrolling down brings it in; that's past the cap, so the top goes.
      render_hook(view, "load_newer_messages", %{})

      assert has_element?(view, "#message-#{held.id}")
      assert rendered(view) == Feed.window()
      refute has_element?(view, "#jump-to-present")
    end

    test "opening another channel counts as being at the bottom again", %{
      view: view,
      server: server,
      user: user
    } do
      render_hook(view, "feed_at_bottom", %{"at_bottom" => false})
      other = channel_fixture(server, user, %{name: "other"})

      render_click(view, "select_channel", %{"id" => other.id})

      # A channel opens scrolled to the bottom, and the hook assumes so too.
      assert :sys.get_state(view.pid).socket.assigns.feed_at_bottom
    end
  end

  describe "the two-way window" do
    alias BanterWeb.ChatLive.Feed

    # A page more than the cap: paging all the way up has to drop the newest.
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)

      messages =
        for n <- 1..(Feed.trim_at() + 50) do
          message_fixture(ctx.channel, ctx.user, %{content: "message #{n}"})
        end

      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")

      ctx |> Map.put(:view, view) |> Map.put(:messages, messages)
    end

    defp detached?(view), do: has_element?(view, "#message-feed[data-has-newer=true]")

    test "paging back past the cap drops the newest and detaches from the present", %{
      view: view,
      messages: messages
    } do
      page_in_everything(view)

      assert rendered(view) == Feed.window()
      assert has_element?(view, "#message-#{hd(messages).id}")
      refute has_element?(view, "#message-#{Enum.at(messages, Feed.window()).id}")
      assert detached?(view)
      assert has_element?(view, "#jump-to-present", "You're viewing older messages")
    end

    test "new messages while detached are held and counted", %{view: view} = ctx do
      page_in_everything(view)

      first = post_live(ctx, "posted while away")
      assert has_element?(view, "#jump-to-present", "1 new message")

      post_live(ctx, "and another")
      assert has_element?(view, "#jump-to-present", "2 new messages")

      refute has_element?(view, "#message-#{first.id}")
      assert rendered(view) == Feed.window()
    end

    test "scrolling back down pages toward the present and reattaches there",
         %{view: view, messages: messages} = ctx do
      page_in_everything(view)
      live_one = post_live(ctx, "posted while away")

      # 201-250: nothing trimmed yet, still detached, still one unseen.
      render_hook(view, "load_newer_messages", %{})
      assert rendered(view) == Feed.trim_at()
      assert has_element?(view, "#jump-to-present", "1 new message")

      # 251-300 takes it past the cap, so the top goes; the live one is still
      # below. Those 50 were on screen before detaching, so they aren't "new".
      render_hook(view, "load_newer_messages", %{})
      assert rendered(view) == Feed.window()
      refute has_element?(view, "#message-#{hd(messages).id}")
      assert has_element?(view, "#jump-to-present", "1 new message")

      # The live one: the present, so the feed reattaches.
      render_hook(view, "load_newer_messages", %{})
      assert has_element?(view, "#message-#{live_one.id}")
      refute detached?(view)
      refute has_element?(view, "#jump-to-present")

      # Attached again, the next message arrives normally.
      next = post_live(ctx, "back in the flow")
      assert has_element?(view, "#message-#{next.id}")
    end

    test "jump to present reopens the newest page", %{view: view, messages: messages} do
      page_in_everything(view)

      view |> element("#jump-to-present button") |> render_click()

      assert rendered(view) == 50
      assert has_element?(view, "#message-#{List.last(messages).id}")
      refute detached?(view)
      refute has_element?(view, "#jump-to-present")
      assert has_element?(view, "#message-feed[data-has-more=true]")
      assert_push_event(view, "scroll_to_present", %{})
    end

    test "the feed never holds more than the cap, whatever the reader does",
         %{view: view} = ctx do
      # Item 3 of the follow-up: with every path trimming as it goes, there's
      # never an over-full feed waiting for a trim when the reader gets back to
      # the bottom. Checked after every step of a long, mixed session.
      within_cap = fn -> assert rendered(view) <= Feed.trim_at() end

      page_up = fn ->
        render_click(view, "load_more_messages", %{})
        within_cap.()
      end

      for _ <- 1..6, do: page_up.()

      for n <- 1..3 do
        post_live(ctx, "away #{n}")
        within_cap.()
      end

      Stream.repeatedly(fn -> render_hook(view, "load_newer_messages", %{}) end)
      |> Stream.each(fn _ -> within_cap.() end)
      |> Enum.find(fn _ -> not detached?(view) end)

      # Back at the present and at the bottom: a busy stretch of live traffic.
      render_hook(view, "feed_at_bottom", %{"at_bottom" => true})

      for n <- 1..120 do
        post_live(ctx, "busy #{n}")
        within_cap.()
      end

      # And back up far enough to cross the cap from the other side.
      for _ <- 1..4, do: page_up.()
      assert detached?(view)
    end
  end

  describe "grouping and redrawing in the feed" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      first = message_fixture(ctx.channel, ctx.user, %{content: "first of the run"})
      second = message_fixture(ctx.channel, ctx.user, %{content: "second of the run"})
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")

      Map.merge(ctx, %{view: view, first: first, second: second})
    end

    test "consecutive messages from one author share a header", %{
      view: view,
      first: first,
      second: second
    } do
      assert has_element?(view, "#message-#{first.id}[data-layout=full]")
      assert has_element?(view, "#message-#{second.id}[data-layout=compact]")
    end

    test "a live message joins the run, and someone else's starts a new one", %{
      view: view,
      server: server,
      channel: channel,
      user: user
    } do
      # Joined before the first send: GuildServer caches its member list when
      # it starts, and the send below starts it.
      other = user_fixture()
      member_fixture(other, server)

      {:ok, mine} = Banter.GuildServer.send_message(server.id, channel.id, user.id, "third")
      assert has_element?(view, "#message-#{mine.id}[data-layout=compact]")

      {:ok, theirs} = Banter.GuildServer.send_message(server.id, channel.id, other.id, "hi")
      assert has_element?(view, "#message-#{theirs.id}[data-layout=full]")
    end

    test "deleting the head of a run gives the next message the header", %{
      view: view,
      server: server,
      user: user,
      first: first,
      second: second
    } do
      :ok = Banter.GuildServer.delete_message(server.id, first.id, user)

      refute has_element?(view, "#message-#{first.id}")
      assert has_element?(view, "#message-#{second.id}[data-layout=full]")
    end

    test "opening another message's menu closes the first", %{
      view: view,
      first: first,
      second: second
    } do
      render_click(view, "select_message", %{"id" => first.id})
      assert has_element?(view, "#msg-menu-#{first.id}")

      render_click(view, "select_message", %{"id" => second.id})
      refute has_element?(view, "#msg-menu-#{first.id}")
      assert has_element?(view, "#msg-menu-#{second.id}")
    end

    test "an edited message says so in either layout", %{
      view: view,
      server: server,
      user: user,
      first: first,
      second: second
    } do
      refute view |> element("#message-#{second.id}") |> render() =~ "(edited)"

      {:ok, _} = Banter.GuildServer.edit_message(server.id, first.id, "reworded", user)
      {:ok, _} = Banter.GuildServer.edit_message(server.id, second.id, "reworded too", user)

      # The compact one has no header row to put the label in, which is how
      # it used to go missing.
      assert has_element?(view, "#message-#{second.id}[data-layout=compact]", "(edited)")
      assert has_element?(view, "#message-#{first.id}[data-layout=full]", "(edited)")
    end

    test "cancelling an edit closes the form", %{view: view, first: first} do
      render_click(view, "start_edit", %{"id" => first.id})
      assert has_element?(view, "#message-#{first.id} form[phx-submit=save_edit]")

      render_click(view, "cancel_edit", %{})
      refute has_element?(view, "#message-#{first.id} form[phx-submit=save_edit]")
    end

    test "cancelling a delete confirmation hides it again", %{view: view, first: first} do
      render_click(view, "confirm_delete", %{"id" => first.id})
      assert has_element?(view, "#message-#{first.id} button[phx-click=delete_message]")

      render_click(view, "cancel_delete", %{})
      refute has_element?(view, "#message-#{first.id} button[phx-click=delete_message]")
    end

    test "a saved edit redraws the message without the form", %{
      view: view,
      first: first
    } do
      render_click(view, "start_edit", %{"id" => first.id})

      render_submit(view, "save_edit", %{"message_id" => first.id, "content" => "reworded"})

      html = view |> element("#message-#{first.id}") |> render()
      assert html =~ "reworded"
      refute html =~ "save_edit"
    end

    test "an empty channel shows its welcome, and it's still there once messages arrive", %{
      conn: conn,
      server: server,
      user: user
    } do
      quiet = channel_fixture(server, user, %{name: "quiet"})
      {:ok, view, _} = live(conn, ~p"/chat/#{server.id}/#{quiet.id}")

      # Always rendered; CSS shows it only while it's the feed's sole child.
      assert has_element?(view, "#messages-empty", "Welcome to #quiet!")

      {:ok, _} =
        Banter.GuildServer.send_message(server.id, quiet.id, user.id, "breaking the silence")

      assert has_element?(view, "#messages-empty")
      assert render(view) =~ "breaking the silence"
    end
  end

  describe "replying to a message" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      message = message_fixture(ctx.channel, ctx.user, %{content: "the original"})
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")

      ctx |> Map.put(:view, view) |> Map.put(:message, message)
    end

    test "starting a reply shows the composer context", %{view: view, message: message} do
      html = render_click(view, "start_reply", %{"id" => message.id})

      assert html =~ "the original" or html =~ "Replying"
    end

    test "sending while replying records reply_to_id", %{
      view: view,
      user: user,
      channel: channel,
      message: message
    } do
      render_click(view, "start_reply", %{"id" => message.id})

      view
      |> element("form[phx-submit='send_message']")
      |> render_submit(%{content: "a reply"})

      {:ok, messages} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      reply = Enum.find(messages, &(&1.content == "a reply"))

      assert reply.reply_to_id == message.id
      assert reply.message_type == :reply
    end

    test "a message from another channel can't be replied to", %{
      view: view,
      user: user,
      server: server,
      channel: channel
    } do
      # The reply target is looked up by id, so the id alone must not be
      # enough: a crafted event naming a message elsewhere in the server is
      # ignored rather than threading a reply across channels.
      elsewhere = channel_fixture(server, user, %{name: "elsewhere"})
      foreign = message_fixture(elsewhere, user, %{content: "over there"})

      html = render_click(view, "start_reply", %{"id" => foreign.id})
      refute html =~ "Replying to"

      view
      |> element("form[phx-submit='send_message']")
      |> render_submit(%{content: "not threaded"})

      {:ok, messages} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      assert Enum.find(messages, &(&1.content == "not threaded")).reply_to_id == nil
    end

    test "an unknown message id is ignored", %{view: view} do
      html = render_click(view, "start_reply", %{"id" => Ash.UUID.generate()})

      refute html =~ "Replying to"
      assert Process.alive?(view.pid)
    end

    test "cancelling a reply clears it, so the next message is a normal one", %{
      view: view,
      user: user,
      channel: channel,
      message: message
    } do
      render_click(view, "start_reply", %{"id" => message.id})
      render_click(view, "cancel_reply", %{})

      view
      |> element("form[phx-submit='send_message']")
      |> render_submit(%{content: "not a reply"})

      {:ok, messages} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      sent = Enum.find(messages, &(&1.content == "not a reply"))

      assert sent.reply_to_id == nil
    end
  end

  describe "the delete confirmation flow" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      message = message_fixture(ctx.channel, ctx.user, %{content: "delete me"})
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")

      ctx |> Map.put(:view, view) |> Map.put(:message, message)
    end

    test "confirming then cancelling leaves the message intact", %{
      view: view,
      user: user,
      channel: channel,
      message: message
    } do
      render_click(view, "confirm_delete", %{"id" => message.id})
      render_click(view, "cancel_delete", %{})

      {:ok, messages} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      assert Enum.any?(messages, &(&1.id == message.id))
    end

    test "selecting and deselecting a message doesn't change it", %{
      view: view,
      user: user,
      channel: channel,
      message: message
    } do
      render_click(view, "select_message", %{"id" => message.id})
      render_click(view, "deselect_message", %{})

      {:ok, messages} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      assert length(messages) == 1
    end
  end

  describe "PubSub-driven updates" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")
      Map.put(ctx, :view, view)
    end

    test "a new channel created elsewhere appears in the sidebar", %{
      view: view,
      server: server,
      user: user
    } do
      refute render(view) =~ "announcements"

      {:ok, _} = Banter.GuildServer.create_channel(server.id, user.id, "announcements")

      assert render(view) =~ "announcements"
    end

    test "someone joining the server appears in the member list", %{
      view: view,
      server: server
    } do
      newcomer = user_fixture()

      {:ok, _} = Banter.GuildServer.join_guild(server.id, newcomer.id, newcomer)

      assert render(view) =~ to_string(newcomer.email)
    end

    test "a typing event from someone else is shown", %{view: view, channel: channel} do
      other = user_fixture()

      send(
        view.pid,
        {:guild_event, {:typing, other.id, "Somebody", channel.id}}
      )

      assert render(view) =~ "Somebody"
    end

    test "a later typing event outlives the earlier one's expiry", %{
      view: view,
      channel: channel
    } do
      other = user_fixture()
      typing = {:guild_event, {:typing, other.id, "Still Typing", channel.id}}

      send(view.pid, typing)
      render(view)
      first_token = :sys.get_state(view.pid).socket.assigns.typing_tokens[other.id]

      send(view.pid, typing)
      render(view)
      latest_token = :sys.get_state(view.pid).socket.assigns.typing_tokens[other.id]

      # The first event's expiry arrives while they're still typing. It used
      # to clear the indicator anyway.
      send(view.pid, {:typing_expired, other.id, first_token})
      assert render(view) =~ "Still Typing is typing"

      send(view.pid, {:typing_expired, other.id, latest_token})
      refute render(view) =~ "Still Typing is typing"
    end

    test "someone's message clears their typing indicator", %{
      view: view,
      server: server,
      channel: channel
    } do
      other = user_fixture()
      member_fixture(other, server)

      send(view.pid, {:guild_event, {:typing, other.id, "Quick Sender", channel.id}})
      assert render(view) =~ "Quick Sender is typing"

      {:ok, _} = Banter.GuildServer.send_message(server.id, channel.id, other.id, "done")

      refute render(view) =~ "Quick Sender is typing"
    end

    test "switching channels clears the indicators", %{
      view: view,
      user: user,
      server: server,
      channel: channel
    } do
      other = user_fixture()
      elsewhere = channel_fixture(server, user, %{name: "elsewhere"})

      send(view.pid, {:guild_event, {:typing, other.id, "Left Behind", channel.id}})
      assert render(view) =~ "Left Behind is typing"

      render_click(view, "select_channel", %{"id" => elsewhere.id})

      refute render(view) =~ "Left Behind is typing"
    end

    test "your own typing event is ignored", %{view: view, user: user, channel: channel} do
      send(view.pid, {:guild_event, {:typing, user.id, "Me Myself", channel.id}})

      refute render(view) =~ "Me Myself is typing"
    end

    test "a typing event for another channel is ignored", %{view: view, user: _user} do
      other = user_fixture()

      send(
        view.pid,
        {:guild_event, {:typing, other.id, "Elsewhere Person", Ash.UUID.generate()}}
      )

      refute render(view) =~ "Elsewhere Person"
    end

    test "an unrecognised message doesn't crash the view", %{view: view} do
      send(view.pid, {:something_unexpected, :entirely})

      assert render(view)
    end
  end

  describe "announcing typing" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")

      # Watch the guild topic the way every other member's view does.
      Phoenix.PubSub.subscribe(Banter.PubSub, "guild:#{ctx.server.id}")

      Map.put(ctx, :view, view)
    end

    # The broadcast happens inside the event handler, so it's already in the
    # mailbox by the time render_hook returns.
    defp typed(view), do: render_hook(view, "typing", %{})

    test "the first typing event is broadcast, and a burst after it is not", %{
      view: view,
      user: user,
      channel: channel
    } do
      typed(view)
      assert_received {:guild_event, {:typing, user_id, _name, channel_id}}
      assert {user_id, channel_id} == {user.id, channel.id}

      for _ <- 1..5, do: typed(view)
      refute_received {:guild_event, {:typing, _, _, _}}
    end

    test "once the interval has passed, the next one is broadcast", %{view: view, channel: channel} do
      typed(view)
      assert_received {:guild_event, {:typing, _, _, _}}

      # Move the last broadcast back in time rather than sleeping through
      # the interval.
      :sys.replace_state(view.pid, fn state ->
        long_ago = System.monotonic_time(:millisecond) - 60_000
        put_in(state.socket.assigns.typing_sent, {channel.id, long_ago})
      end)

      typed(view)
      assert_received {:guild_event, {:typing, _, _, _}}
    end

    test "sending a message ends the bout, so the next keystroke announces at once", %{
      view: view
    } do
      typed(view)
      assert_received {:guild_event, {:typing, _, _, _}}

      view |> element("form[phx-submit='send_message']") |> render_submit(%{content: "sent"})

      typed(view)
      assert_received {:guild_event, {:typing, _, _, _}}
    end

    test "typing in another channel isn't held back by this one", %{
      view: view,
      user: user,
      server: server
    } do
      other = channel_fixture(server, user, %{name: "other"})

      typed(view)
      assert_received {:guild_event, {:typing, _, _, _}}

      render_click(view, "select_channel", %{"id" => other.id})
      typed(view)

      assert_received {:guild_event, {:typing, _, _, other_id}}
      assert other_id == other.id
    end

    test "keystrokes themselves no longer broadcast anything", %{view: view} do
      for text <- ["h", "he", "hel", "hell", "hello"] do
        render_hook(view, "update_message_input", %{"content" => text})
      end

      refute_received {:guild_event, {:typing, _, _, _}}
    end

    test "the composer announces through the hook and debounces the text", %{view: view} do
      assert has_element?(
               view,
               ~s(#message-input[phx-hook="TypingSignal"][phx-debounce="300"][phx-change="update_message_input"])
             )
    end
  end

  describe "UI toggles" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")
      Map.put(ctx, :view, view)
    end

    test "the mobile sidebar opens and closes", %{view: view} do
      view |> render_hook("toggle_mobile_sidebar", %{})
      view |> render_hook("close_mobile_sidebar", %{})

      # Reaching here without raising means both handlers exist and the view
      # survived them; the visual state is a CSS class, not behavior worth
      # pinning.
      assert render(view)
    end

    test "typing in the composer updates the input assign", %{view: view} do
      html = view |> render_hook("update_message_input", %{"content" => "draft"})

      assert html =~ "draft"
    end

    test "the status menu and avatar picker toggle", %{view: view} do
      render_click(view, "toggle_status_menu", %{})
      render_click(view, "toggle_avatar_picker", %{})
      render_click(view, "toggle_avatar_picker", %{})

      assert render(view)
    end

    test "an edit draft survives the message being redrawn", %{
      view: view,
      user: user,
      channel: channel
    } do
      # Sent through the view so the message is on screen — the edit form
      # renders inside it.
      view |> element("form[phx-submit='send_message']") |> render_submit(%{content: "before"})
      {:ok, [message]} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)

      render_click(view, "start_edit", %{"id" => message.id})
      render_click(view, "update_edit", %{"content" => "mid-edit text"})

      # Typing doesn't redraw the message (the browser already shows the
      # text), so force a redraw another way: the author changing avatar
      # redraws everything they wrote. The form must come back with the
      # draft, not the original text.
      render_hook(view, "select_avatar", %{"url" => "/images/avatars/avatar-3.png"})
      html = view |> element("#message-#{message.id}") |> render()

      assert html =~ "mid-edit text"
      assert html =~ "avatar-3.png"
    end

    test "start_edit opens the form on a message loaded with the channel", %{
      conn: conn,
      user: user,
      server: server,
      channel: channel
    } do
      message = message_fixture(channel, user, %{content: "from history"})
      {:ok, view, _} = live(conn, ~p"/chat/#{server.id}/#{channel.id}")

      html = render_click(view, "start_edit", %{"id" => message.id})

      assert html =~ ~s(phx-submit="save_edit")
    end

    test "validate_message keeps the view alive during an upload change", %{view: view} do
      # The upload form's phx-change target. Nothing to assert beyond the view
      # surviving it — the interesting upload behavior is in Storage, covered
      # by its own tests.
      render_change(view, "validate_message", %{"content" => "x"})

      assert render(view)
    end
  end

  describe "attaching an image" do
    setup %{conn: conn} do
      ctx = signed_in_with_server(conn)
      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")

      # Uploads land on the real filesystem, outside the DB sandbox, so they
      # have to be swept explicitly or every run leaves a file behind in
      # priv/static/uploads. Each test has its own server id, so removing that
      # subtree removes exactly this test's files.
      on_exit(fn -> File.rm_rf(Path.join(["priv/static/uploads/servers", ctx.server.id])) end)

      Map.put(ctx, :view, view)
    end

    # A 1x1 PNG — enough to be a real, accepted upload.
    defp png_bytes do
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
      )
    end

    defp attach_png(view, name \\ "pic.png") do
      file_input(view, "form[phx-submit='send_message']", :attachments, [
        %{name: name, content: png_bytes(), type: "image/png"}
      ])
    end

    test "an uploaded image is attached to the sent message", %{
      view: view,
      user: user,
      channel: channel
    } do
      photo = attach_png(view)
      render_upload(photo, "pic.png")

      view |> element("form[phx-submit='send_message']") |> render_submit(%{content: "look"})

      {:ok, [message]} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      {:ok, attachments} = Chat.list_message_attachments(message.id, actor: user)

      assert [attachment] = attachments
      assert attachment.content_type == "image/png"
      assert attachment.filename == "pic.png"
    end

    test "the attachment is stored with a content-type-derived extension", %{
      view: view,
      user: user,
      channel: channel
    } do
      # Cross-checks the SVG stored-XSS fix (AUDIT_FINDINGS.md #8) from the UI
      # side: the stored path comes from the validated content type, not the
      # name the client supplied.
      photo = attach_png(view, "pic.png")
      render_upload(photo, "pic.png")

      view |> element("form[phx-submit='send_message']") |> render_submit(%{content: "look"})

      {:ok, [message]} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      {:ok, [attachment]} = Chat.list_message_attachments(message.id, actor: user)

      assert Path.extname(attachment.storage_path) == ".png"
    end

    test "a file whose bytes aren't an image is refused, even named and typed as one", %{
      view: view,
      user: user,
      channel: channel
    } do
      # LiveView's accept: filter only sees the name and declared type, both of
      # which say PNG here. The contents are an SVG carrying a script — exactly
      # the payload the upload allowlist exists to keep out. Only sniffing the
      # bytes catches it.
      disguised =
        file_input(view, "form[phx-submit='send_message']", :attachments, [
          %{
            name: "innocent.png",
            content: ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|,
            type: "image/png"
          }
        ])

      render_upload(disguised, "innocent.png")
      assert render(view) =~ "innocent.png"

      view |> element("form[phx-submit='send_message']") |> render_submit(%{content: "trust me"})

      {:ok, [message]} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)

      # The message still posts; the attachment does not.
      assert message.content == "trust me"
      assert {:ok, []} = Chat.list_message_attachments(message.id, actor: user)

      # And the rejected file is cleared from the composer rather than sitting
      # there being silently dropped from every later send — with a flash
      # saying why.
      refute has_element?(view, "[data-upload-entry]")
      assert render(view) =~ "Couldn&#39;t attach innocent.png"
    end

    test "a rejected file on its own doesn't post an empty message", %{
      view: view,
      user: user,
      channel: channel
    } do
      disguised =
        file_input(view, "form[phx-submit='send_message']", :attachments, [
          %{name: "bad.png", content: "<svg><script>alert(1)</script></svg>", type: "image/png"}
        ])

      render_upload(disguised, "bad.png")
      view |> element("form[phx-submit='send_message']") |> render_submit(%{content: ""})

      # Nothing to post once the attachment is refused, so no message is
      # written — attempting it would fail the "content or attachments"
      # validation and bury the real reason under a generic error.
      assert {:ok, []} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      refute has_element?(view, "[data-upload-entry]")
      assert render(view) =~ "Couldn&#39;t attach bad.png"
    end

    test "an upload can be cancelled before sending", %{
      view: view,
      user: user,
      channel: channel
    } do
      photo = attach_png(view)
      render_upload(photo, "pic.png")

      assert render(view) =~ "Attachments"

      [entry] = photo.entries
      render_click(view, "cancel_upload", %{"ref" => entry["ref"]})

      refute render(view) =~ "Attachments"

      view |> element("form[phx-submit='send_message']") |> render_submit(%{content: "no image"})

      {:ok, [message]} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)
      assert {:ok, []} = Chat.list_message_attachments(message.id, actor: user)
    end
  end

  # Deliberately not covered here: voice_offer, voice_answer and
  # voice_ice_candidate. Those are WebRTC signaling handlers that forward SDP
  # and ICE payloads to a live Voice.Peer process; exercising them through a
  # LiveView test would mean standing up a real peer connection, and a version
  # that stubbed it would assert nothing the browser actually does. The join /
  # leave / mute / deafen paths above cover the part of voice that has
  # server-side state worth pinning.
end
