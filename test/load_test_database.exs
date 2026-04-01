#!/usr/bin/env elixir

# Database Load Test
# Tests: Database connections, query performance, connection pool
# Run: mix run test/load_test_database.exs

defmodule LoadTest.Database do
  @moduledoc """
  Tests database performance under load.

  This stresses:
  - Database connection pool
  - Query performance
  - Insert/Update throughput
  - Read performance
  """

  require Logger
  alias Banter.{Chat, Repo}

  def run(opts \\ []) do
    target_queries = Keyword.get(opts, :queries, 1000)
    server_id = Keyword.get(opts, :server_id)
    channel_id = Keyword.get(opts, :channel_id)

    Logger.info("💾 Starting Database Load Test")
    Logger.info("   Target Queries: #{target_queries}")

    # Check initial pool status
    check_pool_status()

    # Run different test scenarios
    results = %{}

    Logger.info("\n📖 Testing: Read Performance")
    results = Map.put(results, :reads, test_reads(server_id, channel_id, target_queries))

    Logger.info("\n✍️  Testing: Write Performance")
    results = Map.put(results, :writes, test_writes(server_id, channel_id, div(target_queries, 10)))

    Logger.info("\n🔄 Testing: Concurrent Queries")
    results = Map.put(results, :concurrent, test_concurrent(server_id, channel_id, target_queries))

    # Final report
    report_results(results)
  end

  defp check_pool_status do
    # Get pool configuration
    pool_size = Application.get_env(:banter, Banter.Repo)[:pool_size] || 10

    Logger.info("📊 Database Pool Configuration:")
    Logger.info("   Pool Size: #{pool_size}")
    Logger.info("   Timeout: #{Application.get_env(:banter, Banter.Repo)[:timeout] || 15000}ms")
  end

  defp test_reads(server_id, channel_id, count) do
    start_time = System.monotonic_time(:millisecond)

    results =
      for _ <- 1..count do
        {time, result} =
          :timer.tc(fn ->
            if server_id do
              Chat.get_server(server_id)
            else
              Chat.list_servers()
            end
          end)

        {result, time}
      end

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    successes = Enum.count(results, fn {{status, _}, _} -> status == :ok end)
    avg_query_time = results |> Enum.map(fn {_, time} -> time end) |> Enum.sum() |> div(count)

    Logger.info("   ✅ Success: #{successes}/#{count}")
    Logger.info("   ⏱️  Avg Query Time: #{div(avg_query_time, 1000)}ms")
    Logger.info("   🚀 Queries/Second: #{Float.round(count / (duration / 1000), 2)}")

    %{
      count: count,
      successes: successes,
      avg_time_ms: div(avg_query_time, 1000),
      qps: count / (duration / 1000)
    }
  end

  defp test_writes(server_id, channel_id, count) do
    if !server_id || !channel_id do
      Logger.warning("   ⚠️  Skipping write test (no server/channel ID provided)")
      return %{skipped: true}
    end

    start_time = System.monotonic_time(:millisecond)

    results =
      for i <- 1..count do
        {time, result} =
          :timer.tc(fn ->
            Chat.create_message(%{
              channel_id: channel_id,
              author_id: "load_test_user",
              content: "Load test message #{i}"
            })
          end)

        {result, time}
      end

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    successes = Enum.count(results, fn {{status, _}, _} -> status == :ok end)
    avg_query_time = results |> Enum.map(fn {_, time} -> time end) |> Enum.sum() |> div(count)

    Logger.info("   ✅ Success: #{successes}/#{count}")
    Logger.info("   ⏱️  Avg Write Time: #{div(avg_query_time, 1000)}ms")
    Logger.info("   🚀 Writes/Second: #{Float.round(count / (duration / 1000), 2)}")

    %{
      count: count,
      successes: successes,
      avg_time_ms: div(avg_query_time, 1000),
      wps: count / (duration / 1000)
    }
  end

  defp test_concurrent(server_id, _channel_id, count) do
    start_time = System.monotonic_time(:millisecond)

    # Run queries concurrently
    tasks =
      for _ <- 1..count do
        Task.async(fn ->
          {time, result} =
            :timer.tc(fn ->
              if server_id do
                Chat.get_server(server_id)
              else
                Chat.list_servers()
              end
            end)

          {result, time}
        end)
      end

    results = Task.await_many(tasks, :infinity)

    end_time = System.monotonic_time(:millisecond)
    duration = end_time - start_time

    successes = Enum.count(results, fn {{status, _}, _} -> status == :ok end)
    avg_query_time = results |> Enum.map(fn {_, time} -> time end) |> Enum.sum() |> div(count)

    Logger.info("   ✅ Success: #{successes}/#{count}")
    Logger.info("   ⏱️  Avg Query Time: #{div(avg_query_time, 1000)}ms")
    Logger.info("   🚀 Concurrent QPS: #{Float.round(count / (duration / 1000), 2)}")

    %{
      count: count,
      successes: successes,
      avg_time_ms: div(avg_query_time, 1000),
      qps: count / (duration / 1000)
    }
  end

  defp report_results(results) do
    Logger.info("\n" <> String.duplicate("=", 70))
    Logger.info("📊 DATABASE LOAD TEST RESULTS")
    Logger.info(String.duplicate("=", 70))

    if results.reads do
      Logger.info("\n📖 Read Performance:")
      Logger.info("   Success Rate: #{Float.round(results.reads.successes / results.reads.count * 100, 1)}%")
      Logger.info("   Avg Query Time: #{results.reads.avg_time_ms}ms")
      Logger.info("   Throughput: #{Float.round(results.reads.qps, 2)} queries/sec")
    end

    if results.writes && !results.writes[:skipped] do
      Logger.info("\n✍️  Write Performance:")
      Logger.info("   Success Rate: #{Float.round(results.writes.successes / results.writes.count * 100, 1)}%")
      Logger.info("   Avg Write Time: #{results.writes.avg_time_ms}ms")
      Logger.info("   Throughput: #{Float.round(results.writes.wps, 2)} writes/sec")
    end

    if results.concurrent do
      Logger.info("\n🔄 Concurrent Performance:")
      Logger.info("   Success Rate: #{Float.round(results.concurrent.successes / results.concurrent.count * 100, 1)}%")
      Logger.info("   Avg Query Time: #{results.concurrent.avg_time_ms}ms")
      Logger.info("   Throughput: #{Float.round(results.concurrent.qps, 2)} queries/sec")
    end

    Logger.info("\n" <> String.duplicate("=", 70))
  end
end

# Parse arguments
{opts, _args, _invalid} =
  System.argv()
  |> OptionParser.parse(
    switches: [
      queries: :integer,
      server_id: :string,
      channel_id: :string
    ]
  )

LoadTest.Database.run(opts)
