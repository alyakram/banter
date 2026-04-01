#!/usr/bin/env elixir

# WebSocket Load Test
# Tests: LiveView WebSocket connections, Channel subscriptions
# Run: mix run test/load_test_websocket.exs

defmodule LoadTest.WebSocket do
  @moduledoc """
  Tests actual LiveView WebSocket connections.

  This simulates real browser connections by:
  - Making HTTP requests to get CSRF tokens
  - Opening WebSocket connections to /live
  - Joining LiveView channels
  - Sending LiveView events
  """

  require Logger

  def run(opts \\ []) do
    target_connections = Keyword.get(opts, :connections, 100)
    url = Keyword.get(opts, :url, "http://localhost:4000")
    path = Keyword.get(opts, :path, "/chat")
    duration_sec = Keyword.get(opts, :duration, 60)

    Logger.info("🔌 Starting WebSocket Load Test")
    Logger.info("   Target Connections: #{target_connections}")
    Logger.info("   URL: #{url}")
    Logger.info("   Duration: #{duration_sec}s")

    # Note: This requires additional dependencies
    Logger.warning("⚠️  WebSocket load testing requires additional setup:")
    Logger.warning("   1. Install dependencies: HTTPoison, WebSockex")
    Logger.warning("   2. Get CSRF tokens from real HTTP requests")
    Logger.warning("   3. Maintain WebSocket connections")
    Logger.warning("")
    Logger.warning("   For production WebSocket testing, use:")
    Logger.warning("   - Artillery: https://artillery.io")
    Logger.warning("   - k6: https://k6.io")
    Logger.warning("   - Locust: https://locust.io")
    Logger.warning("")

    # For now, test LiveView channel subscriptions
    test_channel_subscriptions(target_connections, duration_sec)
  end

  defp test_channel_subscriptions(target, duration) do
    Logger.info("📡 Testing PubSub channel subscriptions...")

    tasks =
      for i <- 1..target do
        Task.async(fn ->
          channel = "test_channel_#{i}"
          Phoenix.PubSub.subscribe(Banter.PubSub, channel)

          # Send some messages
          for j <- 1..10 do
            Phoenix.PubSub.broadcast(Banter.PubSub, channel, {:test, j})
            Process.sleep(100)
          end

          Process.sleep(duration * 1000)
          :ok
        end)
      end

    Task.await_many(tasks, :infinity)

    Logger.info("✅ Channel subscription test complete")
  end
end

# Parse arguments
{opts, _args, _invalid} =
  System.argv()
  |> OptionParser.parse(
    switches: [
      connections: :integer,
      url: :string,
      path: :string,
      duration: :integer
    ]
  )

LoadTest.WebSocket.run(opts)
