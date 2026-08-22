defmodule Banter.Chat.Checks.ActorIsServerMember do
  @moduledoc """
  Custom Ash policy check: true if the actor is a member of the server this
  request is scoped to (identified by a `:server_id` argument or attribute
  on the changeset/query).

  Needed specifically for create actions — `expr(exists(server.members, ...))`
  can't be used there because Ash evaluates policy expressions as filters
  against existing data, and a create has no persisted row yet to filter
  ("Cannot use a filter to authorize a create"). This check instead reads
  `server_id` directly off the subject and runs a real membership lookup.
  """
  use Ash.Policy.SimpleCheck

  alias Banter.Chat.Member

  @impl true
  def describe(_opts), do: "actor is a member of the referenced server"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{subject: subject}, _opts) do
    with server_id when not is_nil(server_id) <- server_id_from(subject),
         actor_id when not is_nil(actor_id) <- Map.get(actor, :id) do
      Member
      |> Ash.Query.for_read(:by_user_and_server, %{user_id: actor_id, server_id: server_id})
      |> Ash.exists?(authorize?: false)
    else
      _ -> false
    end
  end

  defp server_id_from(%Ash.Changeset{} = changeset),
    do: Ash.Changeset.get_argument_or_attribute(changeset, :server_id)

  defp server_id_from(%Ash.Query{} = query), do: Ash.Query.get_argument(query, :server_id)
  defp server_id_from(_), do: nil
end
