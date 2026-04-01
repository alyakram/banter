defmodule BanterWeb.Presence do
  @moduledoc """
  Tracks online users across the application using Phoenix.Presence.

  This module provides real-time presence tracking with:
  - Automatic conflict resolution (CRDT)
  - Multi-node support
  - Graceful handling of network partitions

  ## Usage

      # Track a user when they connect
      Presence.track(self(), "users:online", user_id, %{
        online_at: System.system_time(:second),
        status: :online,
        username: user.username
      })

      # Get all online users
      Presence.list("users:online")

      # Subscribe to presence updates
      Phoenix.PubSub.subscribe(Banter.PubSub, "users:online")
  """

  use Phoenix.Presence,
    otp_app: :banter,
    pubsub_server: Banter.PubSub

  @doc """
  Returns a list of all currently online user IDs.
  Excludes users with :invisible status.

  OPTIMIZED: Reads status from Presence metadata instead of database
  to avoid N+1 query problem. Status is kept in sync by update_status/3.
  """
  def online_user_ids do
    "users:online"
    |> list()
    |> Enum.filter(fn {_user_id, %{metas: [meta | _]}} ->
      # Status is already in Presence metadata - no database query!
      Map.get(meta, :status, :online) != :invisible
    end)
    |> Enum.map(fn {user_id, _} -> user_id end)
  end

  @doc """
  Checks if a specific user is online.
  """
  def user_online?(user_id) do
    "users:online"
    |> list()
    |> Map.has_key?(user_id)
  end

  @doc """
  Gets the presence metadata for a user (status, etc.)
  """
  def get_user_presence(user_id) do
    case list("users:online")[user_id] do
      nil -> {:error, :not_found}
      %{metas: [meta | _]} -> {:ok, meta}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Updates a user's status (online, away, dnd, invisible).
  """
  def update_status(pid, user_id, status) when status in [:online, :away, :dnd, :invisible] do
    update(pid, "users:online", user_id, fn meta ->
      Map.put(meta, :status, status)
    end)
  end
end
