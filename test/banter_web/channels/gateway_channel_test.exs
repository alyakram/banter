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
