defmodule BanterWeb.GatewayChannelTest do
  use BanterWeb.ChannelCase

  alias Banter.Accounts
  alias BanterWeb.UserSocket

  defp register_user! do
    email = "gwtest_#{System.unique_integer([:positive])}@example.com"
    password = "correcthorsebatterystaple"

    {:ok, user} =
      Accounts.User
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: email,
        password: password,
        password_confirmation: password
      })
      |> Ash.create(authorize?: false)

    user
  end

  defp connect_info(ip), do: %{peer_data: %{address: ip, port: 0, ssl_cert: nil}}

  defp connect_socket(ip) do
    {:ok, socket} = connect(UserSocket, %{}, connect_info: connect_info(ip))
    socket
  end

  test "connect assigns client_ip from peer_data" do
    socket = connect_socket({203, 0, 113, 5})
    assert socket.assigns.client_ip == "203.0.113.5"
  end

  test "connect rejects once the connection-rate backstop is exceeded" do
    ip = {198, 51, 100, 7}
    info = connect_info(ip)

    results = for _ <- 1..61, do: connect(UserSocket, %{}, connect_info: info)

    # Exact counts (not just "some succeeded, some failed") so an off-by-one
    # in the limit enforcement would actually fail this test.
    assert Enum.count(results, &match?({:ok, _}, &1)) == 60
    assert Enum.count(results, &(&1 == :error)) == 1
  end

  test "connect doesn't crash on a malformed peer address" do
    # Not a valid v4 (4-tuple) or v6 (8-tuple) address — :inet.ntoa/1 returns
    # {:error, :einval} for this, which previously would have crashed
    # peer_ip/1 via to_string/1 on an error tuple.
    info = %{peer_data: %{address: {1, 2, 3}, port: 0, ssl_cert: nil}}

    assert {:ok, socket} = connect(UserSocket, %{}, connect_info: info)
    assert socket.assigns.client_ip == "unknown"
  end

  test "IDENTIFY beyond the auth-attempt limit gets rate-limited, then closes after repeated violations" do
    user = register_user!()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    socket = connect_socket({192, 0, 2, 100})
    {:ok, _reply, socket} = subscribe_and_join(socket, "gateway:connect", %{})
    channel_ref = Process.monitor(socket.channel_pid)
    # The test process is linked to the channel by default; unlink so the
    # channel's deliberate {:shutdown, :rate_limited} exit (asserted via the
    # monitor below) doesn't also crash this test process.
    Process.unlink(socket.channel_pid)

    identify_payload = %{"op" => 2, "d" => %{"token" => token, "guilds" => []}}

    # First 20 attempts stay under the limit. Attempt 1 succeeds and gets no
    # channel reply at all (the ack is an async READY dispatch, not a
    # reply) — attempts 2-20 get rejected by Session as "already
    # identified," which is a normal reply and fine for this test, which
    # only cares that none of them is a rate-limit rejection.
    for i <- 1..20 do
      ref = push(socket, "message", identify_payload)

      if i > 1 do
        receive do
          %Phoenix.Socket.Reply{ref: ^ref, payload: payload} ->
            refute payload[:reason] == "rate_limited"
        after
          1000 -> flunk("no reply received for an under-limit IDENTIFY (attempt #{i})")
        end
      end
    end

    # 21st and 22nd attempts: rate-limited, but under @max_violations (3) —
    # connection stays open.
    for _ <- 1..2 do
      ref = push(socket, "message", identify_payload)
      assert_reply ref, :error, %{reason: "rate_limited"}
    end

    # 23rd attempt crosses @max_violations — the channel should close.
    push(socket, "message", identify_payload)

    assert_receive {:DOWN, ^channel_ref, :process, _pid, {:shutdown, :rate_limited}}, 1000
  end

  describe "sequence numbers" do
    import Banter.Fixtures

    # A client identified into a server it belongs to, READY received. Each
    # test uses its own IP so the per-IP auth rate limit never interferes.
    defp identified(ip) do
      user = user_fixture()
      {server, _} = server_with_owner_fixture(user)
      channel = channel_fixture(server, user)
      {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

      {:ok, _reply, socket} = subscribe_and_join(connect_socket(ip), "gateway:connect", %{})
      push(socket, "message", %{"op" => 2, "d" => %{"token" => token, "guilds" => [server.id]}})
      assert_push "message", %{t: "READY", s: 1}

      %{socket: socket, user: user, server: server, channel: channel, token: token}
    end

    defp guild_event(server, event) do
      Phoenix.PubSub.broadcast(Banter.PubSub, "guild:#{server.id}", {:guild_event, event})
    end

    test "the first event after READY is 2, not a second 1" do
      %{server: server, channel: channel, user: user} = identified({192, 0, 2, 201})

      guild_event(server, {:message_create, message_fixture(channel, user)})

      assert_push "message", %{t: "MESSAGE_CREATE", s: 2}
    end

    test "events the gateway doesn't forward leave no gap" do
      %{server: server, channel: channel, user: user} = identified({192, 0, 2, 202})
      message = message_fixture(channel, user)

      # Typing arrived once per keystroke before it was throttled, and each one
      # used to cost a number.
      for _ <- 1..5, do: guild_event(server, {:typing, user.id, "someone", channel.id})
      guild_event(server, {:message_update, message})
      guild_event(server, {:message_delete, message.id})

      guild_event(server, {:message_create, message})

      assert_push "message", %{t: "MESSAGE_CREATE", s: 2}
    end

    test "every dispatch takes the next number" do
      %{server: server, channel: channel, user: user} = identified({192, 0, 2, 203})

      guild_event(server, {:channel_create, channel})
      guild_event(server, {:message_create, message_fixture(channel, user)})
      guild_event(server, {:member_join, member_fixture(user_fixture(), server)})

      assert_push "message", %{t: "CHANNEL_CREATE", s: 2}
      assert_push "message", %{t: "MESSAGE_CREATE", s: 3}
      assert_push "message", %{t: "GUILD_MEMBER_ADD", s: 4}
    end

    test "RESUMED takes its own number, and events carry on after it" do
      %{socket: socket, server: server, channel: channel, user: user, token: token} =
        identified({192, 0, 2, 204})

      guild_event(server, {:message_create, message_fixture(channel, user)})
      assert_push "message", %{t: "MESSAGE_CREATE", s: 2}

      # RESUME is only accepted from a session that missed its heartbeats.
      [{session_pid, _}] = Registry.lookup(Banter.SessionRegistry, socket.assigns.session_id)
      :sys.replace_state(session_pid, &%{&1 | state: :zombie})

      push(socket, "message", %{"op" => 6, "d" => %{"token" => token, "seq" => 2}})
      assert_push "message", %{t: "RESUMED", s: 3}

      guild_event(server, {:message_create, message_fixture(channel, user)})
      assert_push "message", %{t: "MESSAGE_CREATE", s: 4}
    end
  end

  test "IDENTIFY doesn't crash on a channel socket with no client_ip assign" do
    # Bypass connect/3 entirely via the bare socket/1 helper, simulating a
    # channel socket that somehow never went through it — check_auth_rate/1
    # should fall back to "unknown" instead of raising KeyError.
    user = register_user!()
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    bare_socket = socket(UserSocket)
    {:ok, _reply, socket} = subscribe_and_join(bare_socket, "gateway:connect", %{})

    identify_payload = %{"op" => 2, "d" => %{"token" => token, "guilds" => []}}

    # First attempt succeeds silently (no reply). If check_auth_rate/1 had
    # crashed on the missing assign, the channel process would be dead and
    # this second push would never get a reply at all.
    push(socket, "message", identify_payload)
    ref = push(socket, "message", identify_payload)

    assert_reply ref, :error, %{reason: "identify failed"}
  end
end
