defmodule Banter.Chat.Checks.ActorIsChannelMember do
  @moduledoc """
  Custom Ash policy check: true if the actor is a member of the server that
  owns the channel this request is scoped to (identified by a `:channel_id`
  argument or attribute on the changeset/query).

  Needed for `Message`'s create action for the same reason
  `ActorIsServerMember` is needed for `Channel`'s: `expr(exists(...))` can't
  authorize a create, because Ash evaluates policy expressions as filters
  against persisted data and a create has no row to filter yet. This resolves
  `channel_id` off the subject, looks up which server that channel belongs to,
  and runs a real membership lookup.

  A channel that doesn't exist — or one that's been archived, since
  `Channel` soft-deletes and archived rows are filtered from reads — resolves
  to no membership, so posting into it is denied.
  """
  use Ash.Policy.SimpleCheck

  alias Banter.Chat.{Channel, Member}

  @impl true
  def describe(_opts), do: "actor is a member of the server owning the referenced channel"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{subject: subject}, _opts) do
    with channel_id when not is_nil(channel_id) <- channel_id_from(subject),
         actor_id when not is_nil(actor_id) <- Map.get(actor, :id),
         {:ok, channel} <- Ash.get(Channel, channel_id, authorize?: false) do
      Member
      |> Ash.Query.for_read(:by_user_and_server, %{
        user_id: actor_id,
        server_id: channel.server_id
      })
      |> Ash.exists?(authorize?: false)
    else
      _ -> false
    end
  end

  defp channel_id_from(%Ash.Changeset{} = changeset),
    do: Ash.Changeset.get_argument_or_attribute(changeset, :channel_id)

  defp channel_id_from(%Ash.Query{} = query), do: Ash.Query.get_argument(query, :channel_id)
  defp channel_id_from(_), do: nil
end
