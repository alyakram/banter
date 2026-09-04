defmodule Banter.Fixtures do
  @moduledoc """
  Shared fixtures for resource tests.

  Every fixture creates its record with `authorize?: false` on purpose: a
  fixture's job is to arrange state, not to exercise the policy under test. If
  a fixture ran under policies, a policy regression would show up as a setup
  error in unrelated tests instead of as a failure in the one test that
  actually asserts on it.

  Fixtures return the record itself (not `{:ok, record}`) so setup blocks stay
  flat.
  """

  alias Banter.Accounts
  alias Banter.Chat

  @password "correcthorsebatterystaple"

  @doc "The password every user fixture is created with."
  def password, do: @password

  @doc """
  A unique email address.

  Random rather than a `System.unique_integer/1` counter: that counter restarts
  with each VM, so any row that ever escapes the sandbox and gets committed — a
  crashed test, a `MIX_ENV=test mix run` script — collides with a later run the
  moment its counter reaches the same value. That failed intermittently and
  pointed at everything except the fixture, so it's worth spending eight random
  bytes to make it structurally impossible.
  """
  def unique_email(prefix \\ "user") do
    "#{prefix}_#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}@example.com"
  end

  @doc """
  Creates a user via `:register_with_password`.

  Accepts `:email` and `:password` overrides; anything else is ignored, since
  registration only accepts those (plus the confirmation).
  """
  def user_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    email = Map.get(attrs, :email, unique_email())
    password = Map.get(attrs, :password, @password)

    Accounts.User
    |> Ash.Changeset.for_create(:register_with_password, %{
      email: email,
      password: password,
      password_confirmation: password
    })
    |> Ash.create!(authorize?: false)
  end

  @doc """
  Creates a server owned by `owner`.

  Note this creates the server *only* — no membership row, not even for the
  owner. That mirrors `Chat.Server`'s own create action, and matters because
  the read policy is membership-gated: a server in this state can't be read by
  anyone yet. Use `server_with_owner_fixture/1` for the realistic state.
  """
  def server_fixture(owner, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:name, unique_name("Server"))
      |> Map.put(:owner_id, owner.id)

    Chat.Server
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  @doc """
  Creates a membership joining `user` to `server`.
  """
  def member_fixture(user, server, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.merge(%{user_id: user.id, server_id: server.id})

    Chat.Member
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  @doc """
  Creates a server plus the owner's membership row — the state the app
  actually puts a new server in (GuildServer joins the owner right after
  creating it). Returns `{server, membership}`.
  """
  def server_with_owner_fixture(owner, attrs \\ %{}) do
    server = server_fixture(owner, attrs)
    membership = member_fixture(owner, server, %{role: :owner})
    {server, membership}
  end

  @doc """
  Creates a channel in `server`.

  `creator` is only used to satisfy the create action's shape; the row is
  written with `authorize?: false` like every other fixture.
  """
  def channel_fixture(server, _creator \\ nil, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:name, unique_name("channel"))
      |> Map.put(:server_id, server.id)

    Chat.Channel
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create!(authorize?: false)
  end

  @doc "A unique display name, for resources whose names aren't constrained to be unique."
  def unique_name(prefix) do
    "#{prefix} #{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
  end
end
