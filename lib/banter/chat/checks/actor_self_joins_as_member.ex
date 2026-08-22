defmodule Banter.Chat.Checks.ActorSelfJoinsAsMember do
  @moduledoc """
  Custom Ash policy check for Member's create action: true if the actor is
  creating a membership row for themselves with role :member.

  Written as a custom check rather than `expr(^arg(:user_id) == ... and
  ^arg(:role) == :member)` because `role` isn't always explicitly submitted
  — it falls back to its attribute default of `:member` — and `arg/1` only
  sees explicitly-submitted input, not defaults applied to the attribute.
  Reading `Ash.Changeset.get_attribute/2` instead sees the value post-default.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is self-joining with role :member"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{subject: %Ash.Changeset{} = changeset}, _opts) do
    Ash.Changeset.get_argument_or_attribute(changeset, :user_id) == Map.get(actor, :id) and
      Ash.Changeset.get_attribute(changeset, :role) == :member
  end

  def match?(_actor, _context, _opts), do: false
end
