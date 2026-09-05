defmodule Banter.EnsureStartedRaceTest do
  # Not async: these start real, globally-registered processes and need the
  # shared sandbox so the spawned GuildServer can load its state.
  use Banter.DataCase, async: false

  import Banter.Fixtures

  alias Banter.GuildServer
  alias Banter.Voice

  # Enough concurrency that the window between Registry.lookup returning []
  # and DynamicSupervisor.start_child completing is very likely to be hit by
  # more than one caller.
  @callers 50

  defp race(fun) do
    1..@callers
    |> Enum.map(fn _ -> Task.async(fun) end)
    |> Task.await_many(10_000)
  end

  defp assert_one_winner(results) do
    # The point of the fix: losing the race is not an error. Every caller
    # asked for "a running process for this id", and every caller should get
    # one — the same one.
    errors = Enum.reject(results, &match?({:ok, pid} when is_pid(pid), &1))
    assert errors == [], "expected every caller to get {:ok, pid}, got: #{inspect(errors)}"

    pids = Enum.map(results, fn {:ok, pid} -> pid end)
    assert length(Enum.uniq(pids)) == 1, "expected one shared process, got #{length(Enum.uniq(pids))}"

    hd(pids)
  end

  describe "GuildServer.ensure_started/1" do
    setup do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)
      channel_fixture(server, owner, %{name: "general"})

      on_exit(fn -> stop_guild(server.id) end)

      %{server: server}
    end

    test "concurrent first callers all receive the same running process", %{server: server} do
      results = race(fn -> GuildServer.ensure_started(server.id) end)
      pid = assert_one_winner(results)

      assert Process.alive?(pid)
      assert [{^pid, _}] = Registry.lookup(Banter.GuildRegistry, server.id)
    end

    test "a later caller reuses the process rather than starting another", %{server: server} do
      {:ok, first} = GuildServer.ensure_started(server.id)

      results = race(fn -> GuildServer.ensure_started(server.id) end)
      pid = assert_one_winner(results)

      assert pid == first
    end

    test "the public API doesn't surface a race as a spurious failure", %{server: server} do
      # send_message/4 opens with `with {:ok, _pid} <- ensure_started(...)` and
      # has no else clause, so before the fix a caller that lost the race got
      # {:error, {:already_started, pid}} straight out of a public function
      # that was only asked to send a message.
      #
      # (get_state/1 would not show this — it does its own Registry.lookup
      # rather than going through ensure_started.)
      owner = user_fixture()
      member_fixture(owner, server)
      [channel] = Banter.Chat.list_channels_for_server(server.id)

      results =
        1..@callers
        |> Enum.map(fn n ->
          Task.async(fn ->
            GuildServer.send_message(server.id, channel.id, owner.id, "concurrent #{n}")
          end)
        end)
        |> Task.await_many(10_000)

      refute Enum.any?(results, &match?({:error, {:already_started, _}}, &1)),
             "a lost start race leaked out of send_message/4"
    end
  end

  describe "Voice.Room.ensure_started/1" do
    setup do
      channel_id = Ash.UUID.generate()
      on_exit(fn -> stop_room(channel_id) end)
      %{channel_id: channel_id}
    end

    test "concurrent first callers all receive the same running process", %{
      channel_id: channel_id
    } do
      results = race(fn -> Voice.Room.ensure_started(channel_id) end)
      pid = assert_one_winner(results)

      assert Process.alive?(pid)
      assert [{^pid, _}] = Registry.lookup(Banter.VoiceRoomRegistry, channel_id)
    end

    test "a later caller reuses the process", %{channel_id: channel_id} do
      {:ok, first} = Voice.Room.ensure_started(channel_id)

      results = race(fn -> Voice.Room.ensure_started(channel_id) end)

      assert assert_one_winner(results) == first
    end
  end

  # Helpers

  defp stop_guild(server_id) do
    case Registry.lookup(Banter.GuildRegistry, server_id) do
      [{pid, _}] -> safe_stop(pid)
      [] -> :ok
    end
  end

  defp stop_room(channel_id) do
    case Registry.lookup(Banter.VoiceRoomRegistry, channel_id) do
      [{pid, _}] -> safe_stop(pid)
      [] -> :ok
    end
  end

  defp safe_stop(pid) do
    # These are globally registered and outlive the test that started them, so
    # they have to be cleaned up explicitly. They may also already be gone.
    try do
      GenServer.stop(pid, :normal, 1000)
    catch
      :exit, _ -> :ok
    end
  end
end
