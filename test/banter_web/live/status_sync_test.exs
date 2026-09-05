defmodule BanterWeb.StatusSyncTest do
  @moduledoc """
  Regression tests for AUDIT_FINDINGS.md #10 — status shown from presence metas
  drifting from the database.

  Status used to live in the presence meta of whichever connection wrote it
  last, while a user routinely has several tracked connections (one per tab,
  plus one per gateway session) and readers took `hd(metas)`. These tests pin
  the two symptoms that produced: another viewer seeing a stale status, and the
  user's own other tabs seeing one.
  """
  use BanterWeb.ConnCase

  import Phoenix.LiveViewTest
  import Banter.Fixtures

  alias BanterWeb.Presence

  # From components.ex status_color/1.
  @online "bg-success"
  @away "bg-warning"
  @dnd "bg-error"
  @offline "bg-neutral"

  # The member list renders availability as a coloured dot, so assertions about
  # "what other people see" are assertions about those classes. Scoped to the
  # members sidebar specifically: the viewer's own footer carries a status dot
  # too, and it would otherwise be counted as if it were a member's.
  defp member_dot_classes(view) do
    view
    |> element("aside.w-60")
    |> render()
    |> then(&Regex.scan(~r/bg-(success|warning|error|neutral)/, &1))
    |> Enum.map(&hd/1)
  end

  setup %{conn: conn} do
    owner = user_fixture()
    {server, _} = server_with_owner_fixture(owner)
    channel = channel_fixture(server, owner, %{name: "general"})

    %{owner: owner, server: server, channel: channel, conn: conn}
  end

  describe "a user's own tabs" do
    test "changing status in one tab updates the other tab's footer", %{
      conn: conn,
      owner: owner,
      server: server,
      channel: channel
    } do
      # Two tabs, same user, same session — the exact scenario the finding names.
      {:ok, tab_a, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")
      {:ok, tab_b, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")

      assert render(tab_b) =~ "online"

      render_click(tab_a, "change_status", %{"status" => "away"})

      # The footer renders @current_user.availability. Before the fix the
      # presence_diff handler only refreshed :online_users, so this tab kept
      # showing the old value until it remounted.
      assert render(tab_b) =~ "away"
    end

    test "the tab that made the change shows it too", %{
      conn: conn,
      owner: owner,
      server: server,
      channel: channel
    } do
      {:ok, tab_a, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")

      render_click(tab_a, "change_status", %{"status" => "dnd"})

      assert render(tab_a) =~ "dnd"
    end

    test "a third tab opened afterwards reads the new status from the database", %{
      conn: conn,
      owner: owner,
      server: server,
      channel: channel
    } do
      {:ok, tab_a, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")
      render_click(tab_a, "change_status", %{"status" => "away"})

      {:ok, _tab_c, html} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")

      assert html =~ "away"
    end
  end

  describe "what other members see" do
    setup %{conn: conn, server: server} do
      watcher = user_fixture()
      member_fixture(watcher, server)

      %{watcher: watcher, watcher_conn: log_in_user(conn, watcher)}
    end

    test "a status change is reflected in another member's list", %{
      conn: conn,
      owner: owner,
      server: server,
      channel: channel,
      watcher_conn: watcher_conn
    } do
      {:ok, owner_tab, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")
      {:ok, watcher_tab, _} = live(watcher_conn, ~p"/chat/#{server.id}/#{channel.id}")

      assert @online in member_dot_classes(watcher_tab)

      render_click(owner_tab, "change_status", %{"status" => "dnd"})

      assert @dnd in member_dot_classes(watcher_tab)
    end

    test "an invisible user is shown as offline to others, though still connected", %{
      conn: conn,
      owner: owner,
      server: server,
      channel: channel,
      watcher_conn: watcher_conn
    } do
      {:ok, owner_tab, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")
      {:ok, watcher_tab, _} = live(watcher_conn, ~p"/chat/#{server.id}/#{channel.id}")

      # Both members are connected, so both dots start online.
      assert member_dot_classes(watcher_tab) == [@online, @online]

      render_click(owner_tab, "change_status", %{"status" => "invisible"})

      # Exactly one of the two flips to offline — the owner. The watcher's own
      # row stays online, which is why this counts rather than using `refute`.
      dots = member_dot_classes(watcher_tab)
      assert Enum.count(dots, &(&1 == @offline)) == 1
      assert Enum.count(dots, &(&1 == @online)) == 1

      # ...but the owner still sees their own real status, and is still
      # genuinely connected.
      assert render(owner_tab) =~ "invisible"
      assert MapSet.member?(Presence.connected_user_ids(), owner.id)
    end

    test "a member with no connection at all shows offline", %{
      watcher_conn: watcher_conn,
      server: server,
      channel: channel
    } do
      # The owner exists as a member but has no LiveView mounted.
      {:ok, watcher_tab, _html} = live(watcher_conn, ~p"/chat/#{server.id}/#{channel.id}")

      assert @offline in member_dot_classes(watcher_tab)
    end
  end

  describe "extra tracked connections can't win" do
    test "a second connection for the same user doesn't override the status", %{
      conn: conn,
      owner: owner,
      server: server,
      channel: channel
    } do
      # Stand in for the gateway Session, which tracks the same user under a
      # different pid. It used to publish a `status` meta snapshotted at
      # identify and never updated — so whichever meta came first in the list
      # decided what everyone saw. Nothing reads metas for status now, so this
      # extra connection can only affect *connectivity*.
      watcher = user_fixture()
      member_fixture(watcher, server)

      task =
        Task.async(fn ->
          {:ok, _} =
            Presence.track(self(), "users:online", owner.id, %{
              online_at: System.system_time(:second),
              session_id: "stale-gateway-session"
            })

          receive do
            :stop -> :ok
          end
        end)

      {:ok, owner_tab, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")
      {:ok, watcher_tab, _} = live(log_in_user(conn, watcher), ~p"/chat/#{server.id}/#{channel.id}")

      render_click(owner_tab, "change_status", %{"status" => "away"})

      assert @away in member_dot_classes(watcher_tab)

      send(task.pid, :stop)
      Task.await(task)
    end

    test "a user stays connected while any one of their tabs remains", %{
      conn: conn,
      owner: owner,
      server: server,
      channel: channel
    } do
      {:ok, tab_a, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")
      {:ok, _tab_b, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")

      GenServer.stop(tab_a.pid)

      assert MapSet.member?(Presence.connected_user_ids(), owner.id)
    end
  end

  describe "Presence.connected_user_ids/0" do
    test "reports only connectivity, with no opinion about status", %{
      conn: conn,
      owner: owner,
      server: server,
      channel: channel
    } do
      refute MapSet.member?(Presence.connected_user_ids(), owner.id)

      {:ok, tab, _} = live(log_in_user(conn, owner), ~p"/chat/#{server.id}/#{channel.id}")
      assert MapSet.member?(Presence.connected_user_ids(), owner.id)

      # Invisible still counts as connected here — hiding invisible users is a
      # rendering decision, made where the user record is available.
      render_click(tab, "change_status", %{"status" => "invisible"})
      assert MapSet.member?(Presence.connected_user_ids(), owner.id)
    end
  end
end
