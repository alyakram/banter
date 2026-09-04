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
end
