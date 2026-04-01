#!/usr/bin/env elixir

# Real Server Load Test
# Tests: Server processes, Database connections, PubSub, Memory
# Run: mix run test/load_test_real.exs

defmodule LoadTest.Real do
  @moduledoc """
  Real load testing for Banter server.

  This creates actual Elixir processes that:
  - Connect to Phoenix Presence
  - Subscribe to PubSub channels
  - Send real messages through GuildServer
  - Stress test the database
  """

  require Logger

  def run(opts \\ []) do
    target_users = Keyword.get(opts, :users, 100)
    server_id = Keyword.get(opts, :server_id)
    channel_id = Keyword.get(opts, :channel_id)
    duration_sec = Keyword.get(opts, :duration, 60)

    Logger.info("🚀 Starting REAL load test")
    Logger.info("   Target Users: #{target_users}")
    Logger.info("   Duration: #{duration_sec}s")
    Logger.info("   Server ID: #{server_id}")
    Logger.info("   Channel ID: #{channel_id}")

    # Initial metrics
    initial_memory = :erlang.memory(:total)
    initial_processes = length(Process.list())

    Logger.info("📊 Initial State:")
    Logger.info("   Memory: #{div(initial_memory, 1024 * 1024)}MB")
    Logger.info("   Processes: #{initial_processes}")

    start_time = System.monotonic_time(:millisecond)

    # Start monitoring task
    monitor_task =
      Task.async(fn ->
        monitor_system(duration_sec)
      end)

    # Spawn simulated users
    Logger.info("👥 Spawning #{target_users} user processes...")

    tasks =
      for i <- 1..target_users do
        Task.async(fn ->
          simulate_user(i, server_id, channel_id, duration_sec)
        end)
      end

    # Wait for all users
    results = Task.await_many(tasks, :infinity)
    monitor_stats = Task.await(monitor_task)

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    # Final metrics
    final_memory = :erlang.memory(:total)
    final_processes = length(Process.list())

    # Analyze results
    analyze_results(results, monitor_stats, %{
      initial_memory: initial_memory,
      final_memory: final_memory,
      initial_processes: initial_processes,
      final_processes: final_processes,
      duration: duration,
      target_users: target_users
    })
  end

  defp simulate_user(user_id, server_id, channel_id, duration_sec) do
    user_name = "test_user_#{user_id}"

    try do
      # 1. Track presence (tests Phoenix.Presence + PubSub)
      Phoenix.PubSub.subscribe(Banter.PubSub, "users:online")

      presence_result =
        BanterWeb.Presence.track(
          self(),
          "users:online",
          user_name,
          %{
            online_at: System.system_time(:second),
            status: :online,
            email: "#{user_name}@test.com"
          }
        )

      # 2. Subscribe to guild events (tests PubSub)
      if server_id do
        Phoenix.PubSub.subscribe(Banter.PubSub, "guild:#{server_id}")
      end

      # 3. Send messages periodically (tests GuildServer + Database)
      messages_sent =
        if server_id && channel_id do
          send_messages(server_id, channel_id, user_name, duration_sec)
        else
          0
        end

      # 4. Stay alive for duration
      Process.sleep(duration_sec * 1000)

      # 5. Cleanup
      BanterWeb.Presence.untrack(self(), "users:online", user_name)

      {:ok,
       %{
         user_id: user_id,
         presence: presence_result,
         messages_sent: messages_sent
       }}
    rescue
      error ->
        {:error, %{user_id: user_id, error: error}}
    end
  end

  defp send_messages(server_id, channel_id, user_name, duration_sec) do
    # Send a message every 5 seconds
    num_messages = div(duration_sec, 5)

    for i <- 1..num_messages do
      Process.sleep(5000)

      # This hits the GuildServer GenServer and database
      case Banter.GuildServer.send_message(
             server_id,
             channel_id,
             user_name,
             "Load test message #{i} from #{user_name}"
           ) do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end
    end

    num_messages
  end

  defp monitor_system(duration_sec) do
    samples = div(duration_sec, 2)

    stats =
      for _ <- 1..samples do
        Process.sleep(2000)

        %{
          timestamp: System.monotonic_time(:millisecond),
          memory_mb: div(:erlang.memory(:total), 1024 * 1024),
          processes: length(Process.list()),
          schedulers: :erlang.system_info(:schedulers_online)
        }
      end

    stats
  end

  defp analyze_results(results, monitor_stats, metrics) do
    successes = Enum.count(results, fn {status, _} -> status == :ok end)
    failures = Enum.count(results, fn {status, _} -> status == :error end)

    total_messages =
      results
      |> Enum.filter(fn {status, _} -> status == :ok end)
      |> Enum.map(fn {:ok, data} -> data.messages_sent end)
      |> Enum.sum()

    memory_increase = metrics.final_memory - metrics.initial_memory
    process_increase = metrics.final_processes - metrics.initial_processes

    # Peak metrics from monitoring
    peak_memory =
      monitor_stats
      |> Enum.map(& &1.memory_mb)
      |> Enum.max()

    peak_processes =
      monitor_stats
      |> Enum.map(& &1.processes)
      |> Enum.max()

    Logger.info("\n" <> String.duplicate("=", 70))
    Logger.info("📊 LOAD TEST RESULTS")
    Logger.info(String.duplicate("=", 70))
    Logger.info("")
    Logger.info("✅ Connection Results:")
    Logger.info("   Success: #{successes}/#{metrics.target_users} (#{Float.round(successes / metrics.target_users * 100, 1)}%)")
    Logger.info("   Failures: #{failures}")
    Logger.info("")
    Logger.info("💬 Message Results:")
    Logger.info("   Total Messages Sent: #{total_messages}")
    Logger.info("   Messages/Second: #{Float.round(total_messages / (metrics.duration / 1000), 2)}")
    Logger.info("")
    Logger.info("💾 Memory Usage:")
    Logger.info("   Initial: #{div(metrics.initial_memory, 1024 * 1024)}MB")
    Logger.info("   Final: #{div(metrics.final_memory, 1024 * 1024)}MB")
    Logger.info("   Peak: #{peak_memory}MB")
    Logger.info("   Increase: #{div(memory_increase, 1024 * 1024)}MB")
    Logger.info("   Per User: #{div(memory_increase, metrics.target_users)}KB")
    Logger.info("")
    Logger.info("⚙️  Process Count:")
    Logger.info("   Initial: #{metrics.initial_processes}")
    Logger.info("   Final: #{metrics.final_processes}")
    Logger.info("   Peak: #{peak_processes}")
    Logger.info("   Increase: #{process_increase}")
    Logger.info("")
    Logger.info("⏱️  Duration:")
    Logger.info("   Total: #{Float.round(metrics.duration / 1000, 2)}s")
    Logger.info("")
    Logger.info(String.duplicate("=", 70))

    # Performance rating
    rating =
      cond do
        successes / metrics.target_users >= 0.95 and div(memory_increase, metrics.target_users) < 5_000_000 ->
          "🎉 EXCELLENT"

        successes / metrics.target_users >= 0.90 ->
          "✅ GOOD"

        successes / metrics.target_users >= 0.80 ->
          "⚠️  FAIR"

        true ->
          "❌ NEEDS IMPROVEMENT"
      end

    Logger.info("Overall Rating: #{rating}")
    Logger.info("")
  end
end

# Parse command line arguments
{opts, _args, _invalid} =
  OptionParser.parse(
    System.argv(),
    switches: [
      users: :integer,
      server_id: :string,
      channel_id: :string,
      duration: :integer
    ],
    aliases: [
      u: :users,
      s: :server_id,
      c: :channel_id,
      d: :duration
    ]
  )

# Default configuration
config = [
  users: opts[:users] || 100,
  server_id: opts[:server_id],
  channel_id: opts[:channel_id],
  duration: opts[:duration] || 60
]

# Run the test
LoadTest.Real.run(config)
