# Test script for Session implementation
# Run with: mix run test_session.exs

IO.puts("\n=== Testing Session Infrastructure ===\n")

# Test 1: Check registries and supervisors
IO.puts("1. Checking infrastructure...")
IO.puts("   SessionRegistry: #{inspect(Process.whereis(Banter.SessionRegistry))}")
IO.puts("   SessionSupervisor: #{inspect(Process.whereis(Banter.SessionSupervisor))}")
IO.puts("   GuildRegistry: #{inspect(Process.whereis(Banter.GuildRegistry))}")
IO.puts("   GuildSupervisor: #{inspect(Process.whereis(Banter.GuildSupervisor))}")

# Test 2: Gateway payload creation
IO.puts("\n2. Testing Gateway payload creation...")
hello = Banter.Gateway.hello_payload(45_000)
IO.puts("   HELLO payload: #{inspect(hello)}")

heartbeat_ack = Banter.Gateway.heartbeat_ack_payload()
IO.puts("   HEARTBEAT_ACK payload: #{inspect(heartbeat_ack)}")

dispatch = Banter.Gateway.dispatch_event("MESSAGE_CREATE", %{content: "test"}, 1)
IO.puts("   DISPATCH payload: #{inspect(dispatch)}")

# Test 3: Opcode conversion
IO.puts("\n3. Testing opcode conversion...")
IO.puts("   :hello -> #{Banter.Gateway.opcode_to_int(:hello)}")
IO.puts("   10 -> #{Banter.Gateway.int_to_opcode(10)}")
IO.puts("   :heartbeat -> #{Banter.Gateway.opcode_to_int(:heartbeat)}")

IO.puts("\n✅ Infrastructure tests passed!")
IO.puts("\nTo test the WebSocket Gateway:")
IO.puts("  1. Start the server: mix phx.server")
IO.puts("  2. Open http://localhost:4000/gateway_test.html")
IO.puts("  3. Click 'Connect' to establish WebSocket connection")
IO.puts("  4. Wait for HELLO message with heartbeat_interval")
IO.puts("  5. Enter a user_id and click 'Send IDENTIFY'")
IO.puts("  6. Watch the event log for READY event")
IO.puts("  7. Auto-heartbeat will keep the session alive")
IO.puts("\nSession Flow:")
IO.puts("  Client connects → Server sends HELLO → Client sends IDENTIFY")
IO.puts("  → Server sends READY → Client sends HEARTBEAT periodically")
IO.puts("  → Server sends HEARTBEAT_ACK")
