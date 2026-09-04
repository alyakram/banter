defmodule Banter.Accounts.UserTest do
  use Banter.DataCase, async: true

  import Banter.Fixtures

  alias Banter.Accounts
  alias Banter.Accounts.User

  # The policies block names only :read, :update_availability and
  # :update_avatar. Every other action on this resource is owned by
  # AshAuthentication and is only reachable through it, via the
  # AshAuthenticationInteraction bypass — see the "fail closed" describe block
  # at the bottom, which pins that.
  #
  # So the tests that exercise those actions' *validations* have to run the way
  # AshAuthentication runs them: past the policy check. `authorize?: false` is
  # how we stand in for the bypass, and it keeps each test asserting on one
  # thing — a validation failure here can't be confused with a policy denial.
  defp register(attrs) do
    User
    |> Ash.Changeset.for_create(:register_with_password, attrs)
    |> Ash.create(authorize?: false)
  end

  defp sign_in(email, password) do
    User
    |> Ash.Query.for_read(:sign_in_with_password, %{email: email, password: password})
    |> Ash.read_one(authorize?: false)
  end

  describe "register_with_password" do
    test "creates a user with the given email" do
      email = unique_email()

      assert {:ok, user} =
               register(%{email: email, password: password(), password_confirmation: password()})

      assert to_string(user.email) == email
    end

    test "hashes the password rather than storing it" do
      user = user_fixture()

      assert user.hashed_password
      refute user.hashed_password == password()
      assert Bcrypt.verify_pass(password(), user.hashed_password)
    end

    test "defaults availability to :online" do
      assert user_fixture().availability == :online
    end

    test "returns an authentication token in metadata" do
      assert {:ok, user} =
               register(%{
                 email: unique_email(),
                 password: password(),
                 password_confirmation: password()
               })

      assert is_binary(user.__metadata__.token)
    end

    test "rejects a password shorter than 8 characters" do
      assert {:error, error} =
               register(%{
                 email: unique_email(),
                 password: "short",
                 password_confirmation: "short"
               })

      assert :password in error_fields(error)
    end

    test "rejects a password_confirmation that doesn't match" do
      assert {:error, error} =
               register(%{
                 email: unique_email(),
                 password: password(),
                 password_confirmation: "something else entirely"
               })

      assert :password_confirmation in error_fields(error)
    end

    test "rejects a missing email" do
      assert {:error, error} = register(%{password: password(), password_confirmation: password()})

      assert :email in error_fields(error)
    end

    test "rejects a duplicate email (unique_email identity)" do
      email = unique_email()
      _first = user_fixture(%{email: email})

      assert {:error, error} =
               register(%{email: email, password: password(), password_confirmation: password()})

      assert :email in error_fields(error)
    end

    test "treats email as case-insensitive, so casing can't be used to duplicate" do
      email = unique_email()
      _first = user_fixture(%{email: email})

      assert {:error, _} =
               register(%{
                 email: String.upcase(email),
                 password: password(),
                 password_confirmation: password()
               })
    end
  end

  describe "sign_in_with_password" do
    test "returns the user and a token for correct credentials" do
      user = user_fixture()

      assert {:ok, signed_in} = sign_in(to_string(user.email), password())
      assert signed_in.id == user.id
      assert is_binary(signed_in.__metadata__.token)
    end

    test "fails for a wrong password" do
      user = user_fixture()

      assert {:error, _} = sign_in(to_string(user.email), "not the right password")
    end

    test "fails for an unknown email" do
      assert {:error, _} = sign_in(unique_email("nobody"), password())
    end
  end

  describe "update_availability" do
    for status <- [:online, :away, :dnd, :invisible] do
      test "a user can set their own availability to #{status}" do
        user = user_fixture()

        assert {:ok, updated} =
                 user
                 |> Ash.Changeset.for_update(:update_availability, %{availability: unquote(status)})
                 |> Ash.update(actor: user)

        assert updated.availability == unquote(status)
      end
    end

    test "rejects a value outside the enum" do
      user = user_fixture()

      assert {:error, error} =
               user
               |> Ash.Changeset.for_update(:update_availability, %{availability: :havingfun})
               |> Ash.update(actor: user)

      assert :availability in error_fields(error)
    end

    test "is forbidden when the actor is a different user" do
      user = user_fixture()
      other = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               user
               |> Ash.Changeset.for_update(:update_availability, %{availability: :away})
               |> Ash.update(actor: other)
    end

    test "is forbidden with no actor" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               user
               |> Ash.Changeset.for_update(:update_availability, %{availability: :away})
               |> Ash.update()
    end
  end

  describe "update_user_availability code interface" do
    # Regression tests for a broken `define`: it was declared
    # `args: [:id]`, but :id is the record's primary key rather than an
    # argument on the action, so every call failed with NoSuchInput. Nothing
    # in lib/ called it, so the breakage sat there unnoticed.
    test "accepts the record as the first positional argument" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_user_availability(user, %{availability: :dnd}, actor: user)

      assert updated.id == user.id
      assert updated.availability == :dnd
    end

    test "accepts the record's id as the first positional argument" do
      user = user_fixture()

      assert {:ok, updated} =
               Accounts.update_user_availability(user.id, %{availability: :away}, actor: user)

      assert updated.id == user.id
      assert updated.availability == :away
    end

    test "still enforces the self-only policy" do
      user = user_fixture()
      other = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.update_user_availability(user, %{availability: :dnd}, actor: other)
    end
  end

  describe "update_avatar" do
    test "a user can set their own avatar" do
      user = user_fixture()

      assert {:ok, updated} =
               user
               |> Ash.Changeset.for_update(:update_avatar, %{avatar_url: "/images/avatar-3.png"})
               |> Ash.update(actor: user)

      assert updated.avatar_url == "/images/avatar-3.png"
    end

    test "avatar_url is nullable, so it can be cleared" do
      user = user_fixture()

      {:ok, user} =
        user
        |> Ash.Changeset.for_update(:update_avatar, %{avatar_url: "/images/avatar-3.png"})
        |> Ash.update(actor: user)

      assert {:ok, cleared} =
               user
               |> Ash.Changeset.for_update(:update_avatar, %{avatar_url: nil})
               |> Ash.update(actor: user)

      assert cleared.avatar_url == nil
    end

    test "is forbidden when the actor is a different user" do
      user = user_fixture()
      other = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               user
               |> Ash.Changeset.for_update(:update_avatar, %{avatar_url: "/images/avatar-3.png"})
               |> Ash.update(actor: other)
    end

    test "is forbidden with no actor" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               user
               |> Ash.Changeset.for_update(:update_avatar, %{avatar_url: "/images/avatar-3.png"})
               |> Ash.update()
    end
  end

  describe "read" do
    test "any actor can read users — the :read policy is authorize_if always()" do
      user = user_fixture()
      other = user_fixture()

      assert {:ok, fetched} = Ash.get(User, user.id, actor: other)
      assert fetched.id == user.id
    end

    test "reading is allowed even with no actor at all" do
      user = user_fixture()

      assert {:ok, fetched} = Ash.get(User, user.id)
      assert fetched.id == user.id
    end
  end

  describe "change_password" do
    setup do
      %{user: user_fixture()}
    end

    test "succeeds with the correct current password", %{user: user} do
      assert {:ok, updated} = change_password(user, password(), "a brand new password")
      refute updated.hashed_password == user.hashed_password
      assert Bcrypt.verify_pass("a brand new password", updated.hashed_password)
    end

    test "the old password no longer signs the user in afterwards", %{user: user} do
      {:ok, _} = change_password(user, password(), "a brand new password")

      assert {:error, _} = sign_in(to_string(user.email), password())
      assert {:ok, _} = sign_in(to_string(user.email), "a brand new password")
    end

    test "fails with the wrong current password", %{user: user} do
      assert {:error, _} = change_password(user, "not the current password", "a brand new pw")
    end

    test "fails when the confirmation doesn't match", %{user: user} do
      assert {:error, _} =
               user
               |> Ash.Changeset.for_update(:change_password, %{
                 current_password: password(),
                 password: "a brand new password",
                 password_confirmation: "a different new password"
               })
               |> Ash.update(authorize?: false)
    end

    test "fails when the new password is shorter than 8 characters", %{user: user} do
      assert {:error, _} = change_password(user, password(), "short")
    end
  end

  describe "request_password_reset_token" do
    test "returns :ok for a known email" do
      user = user_fixture()

      assert :ok = request_reset(to_string(user.email))
    end

    test "returns :ok for an unknown email too, so it can't enumerate accounts" do
      assert :ok = request_reset(unique_email("nobody"))
    end
  end

  describe "AshAuthentication-owned actions fail closed" do
    # No policy in this resource names these actions, and Ash forbids an action
    # that no policy matches. That makes them unreachable except through
    # AshAuthentication itself, which trips the AshAuthenticationInteraction
    # bypass. These tests pin that: if someone later adds a broad
    # `policy always()`, or widens an existing one to action_type(:read) /
    # action_type(:update), they break here rather than silently exposing
    # sign-in, registration and password machinery to direct calls.

    test "register_with_password is forbidden for a direct call" do
      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.Changeset.for_create(:register_with_password, %{
                 email: unique_email(),
                 password: password(),
                 password_confirmation: password()
               })
               |> Ash.create()
    end

    test "sign_in_with_password is forbidden for a direct call" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.Query.for_read(:sign_in_with_password, %{
                 email: to_string(user.email),
                 password: password()
               })
               |> Ash.read_one()
    end

    test "get_by_email is forbidden for an ordinary actor" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.Query.for_read(:get_by_email, %{email: to_string(user.email)})
               |> Ash.read_one(actor: user)
    end

    test "get_by_subject is forbidden for an ordinary actor" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.Query.for_read(:get_by_subject, %{subject: "user?id=#{user.id}"})
               |> Ash.read_one(actor: user)
    end

    test "change_password is forbidden for a direct call, even as yourself" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               user
               |> Ash.Changeset.for_update(:change_password, %{
                 current_password: password(),
                 password: "a brand new password",
                 password_confirmation: "a brand new password"
               })
               |> Ash.update(actor: user)
    end

    test "request_password_reset_token is forbidden for a direct call" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               User
               |> Ash.ActionInput.for_action(:request_password_reset_token, %{
                 email: to_string(user.email)
               })
               |> Ash.run_action()
    end
  end

  # Helpers

  defp change_password(user, current, new) do
    user
    |> Ash.Changeset.for_update(:change_password, %{
      current_password: current,
      password: new,
      password_confirmation: new
    })
    |> Ash.update(authorize?: false)
  end

  defp request_reset(email) do
    User
    |> Ash.ActionInput.for_action(:request_password_reset_token, %{email: email})
    |> Ash.run_action(authorize?: false)
  end

  defp error_fields(%{errors: errors}) do
    Enum.flat_map(errors, fn
      %{field: field} when not is_nil(field) -> [field]
      %{fields: fields} when is_list(fields) -> fields
      _ -> []
    end)
  end

  defp error_fields(_), do: []
end
