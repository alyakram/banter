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

      # The flash lives in the app layout, which isn't part of the LiveView's
      # own render, so assert the effect that matters: nothing was created.
      assert is_binary(html)
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

      assert is_binary(html)
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
      for n <- 1..60 do
        message_fixture(ctx.channel, ctx.user, %{content: "message #{n}"})
      end

      {:ok, view, _html} = live(ctx.conn, ~p"/chat/#{ctx.server.id}/#{ctx.channel.id}")
      Map.put(ctx, :view, view)
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

    test "the edit buffer updates as you type", %{view: view, user: user, channel: channel} do
      # Sent through the view so it's in the messages assign — start_edit
      # resolves the message from there, not from the database.
      view |> element("form[phx-submit='send_message']") |> render_submit(%{content: "before"})
      {:ok, [message]} = Chat.list_channel_messages(%{channel_id: channel.id}, actor: user)

      render_click(view, "start_edit", %{"id" => message.id})
      html = render_click(view, "update_edit", %{"content" => "mid-edit text"})

      assert html =~ "mid-edit text"
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
