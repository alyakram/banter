#!/usr/bin/env elixir

# Setup Load Test Server and Channel
# Run: mix run setup_load_test.exs

require Logger

Logger.info("🚀 Setting up load test environment...")

# Create test user (owner) - bypass authorization with authorize?: false
test_user_params = %{
  email: "loadtest@example.com",
  password: "TestPassword123!",
  password_confirmation: "TestPassword123!"
}

test_user =
  case Banter.Accounts.User
       |> Ash.Changeset.for_create(:register_with_password, test_user_params)
       |> Ash.create(authorize?: false) do
    {:ok, user} ->
      Logger.info("✅ Created test user: #{user.email}")
      user

    {:error, _errors} ->
      # User might already exist, try to read it
      Logger.info("User creation failed, trying to find existing user...")

      # Use the by_email action to find the user
      case Banter.Accounts.get_user_by_email("loadtest@example.com", authorize?: false) do
        {:ok, user} ->
          Logger.info("ℹ️  Using existing test user: #{user.email}")
          user

        _ ->
          Logger.error("❌ Failed to create or find test user")
          System.halt(1)
      end
  end

# Create test server (use authorize?: false to bypass policies)
server_params = %{
  name: "Load Test Server - #{:rand.uniform(9999)}",
  owner_id: test_user.id
}

{:ok, server} =
  Banter.Chat.Server
  |> Ash.Changeset.for_create(:create, server_params, actor: test_user)
  |> Ash.create(authorize?: false)

Logger.info("✅ Created server: #{server.name}")
Logger.info("   Server ID: #{server.id}")
Logger.info("   Invite Code: #{server.invite_code}")

# Auto-join owner as member
{:ok, _member} = Banter.GuildServer.join_guild(server.id, test_user.id)
Logger.info("✅ Owner joined server")

# Create test channels
channels = ["general", "random", "load-test", "announcements"]

created_channels =
  Enum.map(channels, fn channel_name ->
    {:ok, channel} =
      Banter.Chat.Channel
      |> Ash.Changeset.for_create(:create, %{name: channel_name, server_id: server.id}, actor: test_user)
      |> Ash.create(authorize?: false)

    Logger.info("✅ Created channel: ##{channel.name}")
    channel
  end)

# Get the load-test channel
load_test_channel = Enum.find(created_channels, &(&1.name == "load-test"))

# Print summary
IO.puts("\n" <> String.duplicate("=", 60))
IO.puts("🎯 LOAD TEST ENVIRONMENT READY!")
IO.puts(String.duplicate("=", 60))
IO.puts("")
IO.puts("📋 Configuration for load_test_10k.html:")
IO.puts("")
IO.puts("  Server ID:  #{server.id}")
IO.puts("  Channel ID: #{load_test_channel.id}")
IO.puts("")
IO.puts("🔗 URLs:")
IO.puts("")
IO.puts("  Load Test:  http://localhost:4000/load_test_10k.html")
IO.puts("  Chat:       http://localhost:4000/chat/#{server.id}/#{load_test_channel.id}")
IO.puts("")
IO.puts("🔑 Test Credentials:")
IO.puts("")
IO.puts("  Email:      loadtest@example.com")
IO.puts("  Password:   TestPassword123!")
IO.puts("  Invite:     #{server.invite_code}")
IO.puts("")
IO.puts(String.duplicate("=", 60))
IO.puts("")
IO.puts("💡 Quick Start:")
IO.puts("")
IO.puts("  1. Open http://localhost:4000/load_test_10k.html")
IO.puts("  2. Paste Server ID and Channel ID above")
IO.puts("  3. Set Target Users: 100")
IO.puts("  4. Click 'Start Load Test'")
IO.puts("")
IO.puts("📊 Monitor with:")
IO.puts("")
IO.puts("  iex> Process.list() |> length()")
IO.puts("  iex> :erlang.memory(:total) |> div(1024*1024)")
IO.puts("  iex> :observer.start()")
IO.puts("")
