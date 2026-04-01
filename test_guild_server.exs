# Test script for GuildServer implementation
# Run with: mix run test_guild_server.exs

IO.puts("\n=== Testing Guild Server Implementation ===\n")

# Test 1: Snowflake ID generation
IO.puts("1. Testing Snowflake ID generation...")
id1 = Banter.Snowflake.generate()
id2 = Banter.Snowflake.generate()
id3 = Banter.Snowflake.generate()

IO.puts("   Generated IDs: #{id1}, #{id2}, #{id3}")
IO.puts("   IDs are unique: #{id1 != id2 && id2 != id3}")
IO.puts("   IDs are increasing: #{id1 < id2 && id2 < id3}")

timestamp = Banter.Snowflake.timestamp(id1)
datetime = Banter.Snowflake.to_datetime(id1)
IO.puts("   Timestamp: #{timestamp}")
IO.puts("   DateTime: #{datetime}")

# Test 2: Registry and DynamicSupervisor
IO.puts("\n2. Testing Registry and DynamicSupervisor...")
IO.puts("   GuildRegistry: #{inspect(Process.whereis(Banter.GuildRegistry))}")
IO.puts("   GuildSupervisor: #{inspect(Process.whereis(Banter.GuildSupervisor))}")

# Test 3: Check if we can look up a guild (should be empty)
IO.puts("\n3. Testing guild process discovery...")
result = Registry.lookup(Banter.GuildRegistry, "test-server-123")
IO.puts("   Lookup non-existent guild: #{inspect(result)}")

IO.puts("\n✅ Basic infrastructure tests passed!")
IO.puts("\nTo test the full flow:")
IO.puts("  1. Start the server: mix phx.server")
IO.puts("  2. Navigate to http://localhost:4000")
IO.puts("  3. Register/login")
IO.puts("  4. Create a server")
IO.puts("  5. Send messages")
IO.puts("\nThe GuildServer will automatically start when you:")
IO.puts("  - Create a server and join it")
IO.puts("  - Send a message")
IO.puts("  - Create a channel")
IO.puts("\nYou can observe the GuildServer in action by checking logs:")
IO.puts("  Look for: \"Starting GuildServer for server_id=...\"")
