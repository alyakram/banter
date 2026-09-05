defmodule BanterWeb.Presence do
  @moduledoc """
  Tracks online users across the application using Phoenix.Presence.

  This module provides real-time presence tracking with:
  - Automatic conflict resolution (CRDT)
  - Multi-node support
  - Graceful handling of network partitions

  ## What this does and does not answer

  Presence answers **who is connected**, and nothing else. A user's
  availability (`:online`/`:away`/`:dnd`/`:invisible`) lives in the database,
  on `users.availability`, and is read from the user record — never from a
  presence meta.

  That split matters because a single user routinely has several tracked
  entries under the same key: one per open browser tab (`ChatLive.mount/3`)
  plus one per gateway session (`Banter.Session`). Phoenix promises nothing
  about the order of those metas. Storing status in them meant the status
  everyone saw was whichever meta happened to be first, and a change made in
  one tab left the others stale.

  ## Usage

      # Track a user when they connect
      Presence.track(self(), "users:online", user_id, %{
        online_at: System.system_time(:second),
        email: user.email
      })

      # Who is currently connected
      Presence.connected_user_ids()

      # Subscribe to presence updates
      Phoenix.PubSub.subscribe(Banter.PubSub, "users:online")
  """

  use Phoenix.Presence,
    otp_app: :banter,
    pubsub_server: Banter.PubSub

  @topic "users:online"

  @doc """
  The ids of every user with at least one live connection, as a `MapSet`.

  Deliberately says nothing about availability. Callers combine this with the
  user's own `availability` field to decide what to show — a user is rendered
  offline when they aren't in this set, and also when they are but have set
  themselves invisible.
  """
  def connected_user_ids do
    @topic
    |> list()
    |> Map.keys()
    |> MapSet.new()
  end
end
