defmodule BanterWeb.ChatLive.Feed do
  @moduledoc """
  The channel's message feed, kept as a LiveView stream.

  A stream sends each message to the browser once and then drops it from the
  LiveView process, so the process's memory no longer grows with how long a
  channel has been open or how far back someone scrolled. What the process
  does keep is `:rendered_messages` — one small entry per message on screen
  (id, author, time), oldest first. Two things need it: grouping, since whether a message renders
  compact depends on the one above it; and knowing which messages a change
  affects, so only those are redrawn.

  The one non-obvious rule: stream items don't re-render when assigns change.
  Anything that alters how a rendered message looks — an edit, its menu
  opening, the message above it being deleted — has to insert that message
  again. `rerender/2` does that, re-reading the messages by id.
  """

  import Phoenix.Component, only: [assign: 3]

  import Phoenix.LiveView,
    only: [stream_configure: 3, stream: 4, stream_insert: 4, stream_delete_by_dom_id: 3]

  alias Banter.Chat

  require Logger

  # What a rendered message needs loaded.
  @loads [:author, :attachments, reply_to: [:author]]

  # A message within this many minutes of the previous one, by the same
  # author, renders compact — no avatar or name.
  @group_minutes 5

  def loads, do: @loads

  def dom_id(message_id), do: "message-#{message_id}"

  @doc "Sets up an empty feed. Call once, from mount."
  def init(socket) do
    socket
    |> stream_configure(:messages, dom_id: &dom_id(&1.id))
    |> stream(:messages, [], [])
    |> assign(:rendered_messages, [])
  end

  @doc "Replaces the feed with `messages`, oldest first."
  def reset(socket, messages) do
    entries = Enum.map(messages, &entry/1)

    socket
    |> stream(:messages, items(messages, nil), reset: true)
    |> assign(:rendered_messages, entries)
  end

  @doc "Adds a message below everything rendered."
  def append(socket, message) do
    if rendered?(socket, message.id) do
      replace(socket, message)
    else
      prev = List.last(socket.assigns.rendered_messages)

      socket
      |> stream_insert(:messages, item(message, prev), at: -1)
      |> assign(:rendered_messages, socket.assigns.rendered_messages ++ [entry(message)])
    end
  end

  @doc """
  Adds `older` (oldest first) above everything rendered.

  The message that used to be first now has one above it, so it's redrawn —
  it may join the run of the last older message.
  """
  def prepend(socket, []), do: socket

  def prepend(socket, older) do
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
