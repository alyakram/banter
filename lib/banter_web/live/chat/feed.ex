defmodule BanterWeb.ChatLive.Feed do
  @moduledoc """
  The channel's message feed, kept as a LiveView stream.

  A stream sends each message to the browser once and then drops it from the
  LiveView process, so the process's memory no longer grows with how long a
  channel has been open or how far back someone scrolled. What the process
  does keep is `:rendered_messages` — one small entry per message on screen
  (id, author, time), oldest first. Two things need it: grouping, since
  whether a message renders compact depends on the one above it; and knowing
  which messages a change affects, so only those are redrawn.

  ## A window, not the whole channel

  The browser holds at most 250 messages, whichever way the reader goes.
  Past that the far end is trimmed back to 200: loading older messages drops
  the newest, loading newer ones drops the oldest. Dropping the newest leaves
  the feed *detached* from the present (`:has_newer_messages`) — there are
  messages below what's on screen, and scrolling down loads them back.

  A live message is placed according to where the reader is:

  - detached: held, and counted (`:unseen_count`) for the "new messages" bar;
  - at the bottom (`:feed_at_bottom`, from the FeedEnd hook): appended, and
    the top trimmed if that takes the feed past the cap;
  - scrolled up with room to spare: appended;
  - scrolled up with the feed full: held, and the feed detaches. Trimming the
    top here would pull away what's being read.

  Because every path keeps to the cap, the feed never sits over it waiting
  for a trim — there's nothing to catch up on when the reader returns to the
  bottom.

  The one non-obvious rule: stream items don't re-render when assigns change.
  Anything that alters how a rendered message looks — an edit, its menu
  opening, the message above it being deleted — has to insert that message
  again. `rerender/2` does that, re-reading the messages by id.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]

  import Phoenix.LiveView,
    only: [
      push_event: 3,
      stream_configure: 3,
      stream: 4,
      stream_insert: 4,
      stream_delete_by_dom_id: 3
    ]

  alias Banter.Chat

  require Logger

  # What a rendered message needs loaded.
  @loads [:author, :attachments, reply_to: [:author]]

  # A message within this many minutes of the previous one, by the same
  # author, renders compact — no avatar or name.
  @group_minutes 5

  # Messages per page; the read actions fetch one more to tell if there's
  # another page.
  @page_size 50

  # Trimming starts past @trim_at and cuts back to @window. The gap between
  # them is a page, so a busy channel trims (and redraws its new first
  # message) once per page rather than on every message.
  @window 200
  @trim_at 250

  def window, do: @window
  def trim_at, do: @trim_at

  def dom_id(message_id), do: "message-#{message_id}"

  @doc "Sets up an empty feed. Call once, from mount."
  def init(socket) do
    socket
    |> stream_configure(:messages, dom_id: &dom_id(&1.id))
    |> stream(:messages, [], [])
    |> reset_state([])
  end

  @doc """
  Replaces the feed with `messages`, oldest first, as the present — nothing
  newer, reader at the bottom (a channel opens scrolled there).
  """
  def reset(socket, messages) do
    socket
    |> stream(:messages, items(messages, nil), reset: true)
    |> reset_state(messages)
  end

  @doc "Opens the channel on its newest page. Also what \"Jump to present\" does."
  def load_latest(socket, channel_id) do
    {:ok, rows} = Chat.list_channel_messages(%{channel_id: channel_id}, actor: actor(socket))
    {page, more?} = page(rows)

    socket
    |> reset(page |> Enum.reverse() |> load(socket))
    |> assign(:has_more_messages, more?)
  end

  @doc "Loads the page above the first rendered message. Past the cap, drops the newest."
  def load_older(socket) do
    {:ok, rows} =
      Chat.list_channel_messages(
        %{channel_id: channel_id(socket), before_id: socket.assigns.messages_cursor},
        actor: actor(socket)
      )

    {page, more?} = page(rows)
    older = page |> Enum.reverse() |> load(socket)

    socket
    |> prepend(older)
    |> assign(:messages_cursor, first_id(older) || socket.assigns.messages_cursor)
    |> assign(:has_more_messages, more?)
    |> trim_bottom()
  end

  @doc """
  Loads the page below the last rendered message, for a detached feed. Past
  the cap, drops the oldest; reaching the present reattaches.
  """
  def load_newer(socket) do
    {:ok, rows} =
      Chat.list_newer_channel_messages(
        %{channel_id: channel_id(socket), after_id: socket.assigns.newer_cursor},
        actor: actor(socket)
      )

    {page, more?} = page(rows)
    newer = load(page, socket)

    socket
    |> append_page(newer)
    |> caught_up(newer, more?)
    |> trim_top()
  end

  @doc "Places a message that has just been posted. See the moduledoc for the rule."
  def live_message(socket, message) do
    %{rendered_messages: entries, has_newer_messages: detached?} = socket.assigns

    cond do
      detached? ->
        update_unseen(socket, 1)

      socket.assigns.feed_at_bottom ->
        socket
        |> append(load(message, socket))
        |> trim_top()
        |> push_event("scroll_to_bottom", %{})

      length(entries) < @trim_at ->
        socket
        |> append(load(message, socket))
        |> push_event("scroll_to_bottom", %{})

      true ->
        socket |> detach() |> update_unseen(1)
    end
  end

  # Adds a message below everything rendered.
  defp append(socket, message) do
    if rendered?(socket, message.id) do
      replace(socket, message)
    else
      prev = List.last(socket.assigns.rendered_messages)

      socket
      |> stream_insert(:messages, item(message, prev), at: -1)
      |> assign(:rendered_messages, socket.assigns.rendered_messages ++ [entry(message)])
    end
  end

  # Adds `older` (oldest first) above everything rendered. The message that
  # used to be first now has one above it, so it's redrawn — it may join the
  # run of the last older message.
  defp prepend(socket, []), do: socket

  defp prepend(socket, older) do
    old_first = List.first(socket.assigns.rendered_messages)

    socket
    # Inserting a list at 0 puts each item at 0 in turn; reversing keeps the
    # list's own order on screen.
    |> stream(:messages, Enum.reverse(items(older, nil)), at: 0)
    |> assign(
      :rendered_messages,
      Enum.map(older, &entry/1) ++ socket.assigns.rendered_messages
    )
    |> rerender(List.wrap(old_first && old_first.id))
  end

  @doc "Redraws `message` in place if it's rendered; otherwise does nothing."
  def replace(socket, message) do
    case previous(socket.assigns.rendered_messages, message.id) do
      {:ok, prev} -> stream_insert(socket, :messages, item(message, prev), update_only: true)
      :error -> socket
    end
  end

  @doc """
  Removes a message if it's rendered. The one below it is redrawn, since the
  message above it has changed.
  """
  def delete(socket, message_id) do
    entries = socket.assigns.rendered_messages

    case Enum.find_index(entries, &(&1.id == message_id)) do
      nil ->
        socket

      index ->
        following = Enum.at(entries, index + 1)

        socket
        |> stream_delete_by_dom_id(:messages, dom_id(message_id))
        |> assign(:rendered_messages, List.delete_at(entries, index))
        |> rerender(List.wrap(following && following.id))
    end
  end

  @doc """
  Re-reads the given messages and redraws the ones that are rendered, using
  the current assigns. Ids that aren't rendered (or are nil) are ignored, so
  callers can pass the before and after of a UI state without checking.
  """
  def rerender(socket, ids) do
    rendered = MapSet.new(socket.assigns.rendered_messages, & &1.id)
    ids = ids |> Enum.filter(&MapSet.member?(rendered, &1)) |> Enum.uniq()

    with [_ | _] <- ids,
         {:ok, messages} <-
           Chat.list_messages_by_ids(ids, actor: socket.assigns.current_user, load: @loads) do
      Enum.reduce(messages, socket, &replace(&2, &1))
    else
      [] ->
        socket

      {:error, error} ->
        # The messages stay as they were drawn; nothing is lost but a redraw.
        Logger.warning("[ChatLive.Feed] couldn't re-read messages: #{inspect(error)}")
        socket
    end
  end

  @doc "Redraws every rendered message written by `user_id`."
  def rerender_user(socket, user_id) do
    ids = for %{author_id: ^user_id, id: id} <- socket.assigns.rendered_messages, do: id

    rerender(socket, ids)
  end

  def rendered?(socket, message_id) do
    Enum.any?(socket.assigns.rendered_messages, &(&1.id == message_id))
  end

  # ── Private ─────────────────────────────────────────────────────────

  defp reset_state(socket, messages) do
    socket
    |> assign(:rendered_messages, Enum.map(messages, &entry/1))
    |> assign(:feed_at_bottom, true)
    |> assign(:messages_cursor, first_id(messages))
    |> assign(:has_more_messages, false)
    |> attach()
  end

  # Oldest first; `older` and `newer` pages are ordered this way too.
  defp page(rows), do: {Enum.take(rows, @page_size), length(rows) > @page_size}

  defp load([], _socket), do: []
  defp load(messages, socket), do: Ash.load!(messages, @loads, actor: actor(socket))

  defp actor(socket), do: socket.assigns.current_user
  defp channel_id(socket), do: socket.assigns.current_channel.id
  defp first_id([first | _]), do: first.id
  defp first_id([]), do: nil

  defp append_page(socket, []), do: socket

  defp append_page(socket, newer) do
    entries = socket.assigns.rendered_messages

    socket
    |> stream(:messages, items(newer, List.last(entries)), at: -1)
    |> assign(:rendered_messages, entries ++ Enum.map(newer, &entry/1))
  end

  # Keeps the newest @window once past the cap. The trimmed messages become
  # the next page up, and the new first message is redrawn — it may have been
  # drawn compact under one that's gone.
  defp trim_top(socket) do
    entries = socket.assigns.rendered_messages

    if length(entries) > @trim_at do
      {trimmed, [first | _] = kept} = Enum.split(entries, length(entries) - @window)

      socket
      |> delete_entries(trimmed)
      |> assign(:rendered_messages, kept)
      |> assign(:messages_cursor, first.id)
      |> assign(:has_more_messages, true)
      |> rerender([first.id])
    else
      socket
    end
  end

  # Keeps the oldest @window once past the cap. What's trimmed is now below
  # the feed, so it detaches. Nothing needs redrawing: grouping looks upward.
  defp trim_bottom(socket) do
    entries = socket.assigns.rendered_messages

    if length(entries) > @trim_at do
      {kept, trimmed} = Enum.split(entries, @window)

      socket
      |> detach()
      |> delete_entries(trimmed)
      |> assign(:rendered_messages, kept)
      |> assign(:newer_cursor, List.last(kept).id)
    else
      socket
    end
  end

  defp delete_entries(socket, entries) do
    Enum.reduce(entries, socket, &stream_delete_by_dom_id(&2, :messages, dom_id(&1.id)))
  end

  # Detached: messages exist below the last rendered one. `seen_through_id` is
  # the newest message the reader had on screen when it happened — anything
  # after it counts as unseen once loaded. Detaching again while already
  # detached keeps the original mark.
  defp detach(%{assigns: %{has_newer_messages: true}} = socket), do: socket

  defp detach(socket) do
    last_id = socket.assigns.rendered_messages |> List.last() |> Map.get(:id)

    assign(socket,
      has_newer_messages: true,
      newer_cursor: last_id,
      seen_through_id: last_id
    )
  end

  defp attach(socket) do
    assign(socket,
      has_newer_messages: false,
      newer_cursor: nil,
      seen_through_id: nil,
      unseen_count: 0
    )
  end

  # After loading a newer page: the ones posted since detaching are seen now,
  # and a short page means the present has been reached.
  defp caught_up(socket, _newer, false), do: attach(socket)

  defp caught_up(socket, newer, true) do
    seen_through = socket.assigns.seen_through_id
    now_seen = Enum.count(newer, &(&1.id > seen_through))

    socket
    |> assign(:newer_cursor, List.last(newer).id)
    |> update_unseen(-now_seen)
  end

  defp update_unseen(socket, by) do
    assign(socket, :unseen_count, max(socket.assigns.unseen_count + by, 0))
  end

  # Stream items for consecutive messages, the first following `prev`.
  defp items(messages, prev) do
    {items, _last} =
      Enum.map_reduce(messages, prev, fn message, prev ->
        {item(message, prev), message}
      end)

    items
  end

  defp item(message, prev) do
    %{
      id: message.id,
      message: message,
      compact: compact?(message, prev),
      divider: not is_nil(prev)
    }
  end

  defp compact?(_message, nil), do: false

  defp compact?(message, prev) do
    prev.author_id == message.author_id and
      DateTime.diff(message.inserted_at, prev.inserted_at, :minute) <= @group_minutes
  end

  defp entry(message) do
    %{id: message.id, author_id: message.author_id, inserted_at: message.inserted_at}
  end

  # The entry rendered just above `message_id`: {:ok, nil} for the first one,
  # :error when it isn't rendered at all.
  defp previous(entries, message_id) do
    entries
    |> Enum.zip([nil | entries])
    |> Enum.find_value(:error, fn {entry, prev} -> entry.id == message_id && {:ok, prev} end)
  end
end
