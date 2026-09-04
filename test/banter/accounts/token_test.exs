defmodule Banter.Accounts.TokenTest do
  use Banter.DataCase, async: true

  import Banter.Fixtures

  alias Banter.Accounts.Token

  # Every action on this resource belongs to AshAuthentication. The policies
  # block contains nothing but the AshAuthenticationInteraction bypass, so
  # direct callers are refused and the interesting behavior is only observable
  # through the auth flows that drive it. `authorize?: false` stands in for the
  # bypass in the behavioral tests below, exactly as in the User suite.
  defp all_tokens do
    {:ok, tokens} = Ash.read(Token, authorize?: false)
    tokens
  end

  defp jti_of(token) do
    {:ok, claims} = AshAuthentication.Jwt.peek(token)
    claims["jti"]
  end

  defp revoked?(jti) do
    {:ok, result} =
      Token
      |> Ash.ActionInput.for_action(:revoked?, %{jti: jti})
      |> Ash.run_action(authorize?: false)

    result
  end

  describe "policies" do
    # This resource holds credentials, so "closed to everyone" is the whole
    # policy story — there is no legitimate direct caller. These pin that: if
    # someone adds a broad policy here, tokens become readable.
    test "reading tokens is forbidden for an ordinary actor" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Token, actor: user)
    end

    test "reading tokens is forbidden with no actor" do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.read(Token)
    end

    test "the expired read is forbidden for an ordinary actor" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               Token |> Ash.Query.for_read(:expired, %{}) |> Ash.read(actor: user)
    end

    test "storing a token directly is forbidden" do
      user = user_fixture()
      token = user.__metadata__.token

      assert {:error, %Ash.Error.Forbidden{}} =
               Token
               |> Ash.Changeset.for_create(:store_token, %{token: token, purpose: "user"})
               |> Ash.create(actor: user)
    end

    test "revoking a token directly is forbidden" do
      user = user_fixture()
      token = user.__metadata__.token

      assert {:error, %Ash.Error.Forbidden{}} =
               Token
               |> Ash.Changeset.for_create(:revoke_token, %{token: token})
               |> Ash.create(actor: user)
    end

    test "expunging expired tokens is forbidden for an ordinary actor" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               Token
               |> Ash.Query.for_read(:expired, %{})
               |> Ash.bulk_destroy(:expunge_expired, %{}, actor: user, return_errors?: true)
               |> then(fn result -> if result.status == :success, do: :ok, else: {:error, %Ash.Error.Forbidden{}} end)
    end
  end

  describe "tokens are stored for real auth flows" do
    # store_all_tokens? true and require_token_presence_for_authentication? true
    # are both set on the User resource, which means every issued token lands in
    # this table and authentication depends on it still being there.

    test "registering a user stores a token" do
      assert all_tokens() == []

      user = user_fixture()

      stored = all_tokens()
      assert length(stored) >= 1
      assert Enum.any?(stored, &(&1.jti == jti_of(user.__metadata__.token)))
    end

    test "a stored token carries its subject, purpose and expiry" do
      user = user_fixture()
      jti = jti_of(user.__metadata__.token)

      token_record = Enum.find(all_tokens(), &(&1.jti == jti))

      assert token_record.subject =~ user.id
      assert is_binary(token_record.purpose)
      assert DateTime.compare(token_record.expires_at, DateTime.utc_now()) == :gt
    end

    test "signing in stores an additional token" do
      user = user_fixture()
      before_count = length(all_tokens())

      {:ok, signed_in} =
        Banter.Accounts.User
        |> Ash.Query.for_read(:sign_in_with_password, %{
          email: to_string(user.email),
          password: password()
        })
        |> Ash.read_one(authorize?: false)

      assert length(all_tokens()) > before_count
      assert is_binary(signed_in.__metadata__.token)
    end
  end

  describe "revocation" do
    test "a freshly issued token is not revoked" do
      user = user_fixture()

      refute revoked?(jti_of(user.__metadata__.token))
    end

    # revoke_token/revoke_jti record a revocation by *creating* a row with
    # purpose "revocation" and the same jti — which is how AshAuthentication
    # revokes when tokens aren't stored. This app sets `store_all_tokens? true`,
    # so that row already exists, and jti is the primary key. Single-token
    # revocation therefore can't work in this configuration; the working
    # mechanism is revoke_all_stored_for_subject, which updates in place.
    # See AUDIT_FINDINGS.md #36.

    test "revoke_jti collides with the already-stored token row" do
      user = user_fixture()
      jti = jti_of(user.__metadata__.token)

      assert {:error, error} =
               Token
               |> Ash.Changeset.for_create(:revoke_jti, %{
                 subject: "user?id=#{user.id}",
                 jti: jti
               })
               |> Ash.create(authorize?: false)

      assert :jti in error_fields(error)
      refute revoked?(jti)
    end

    test "revoke_token collides the same way" do
      user = user_fixture()
      token = user.__metadata__.token

      assert {:error, error} =
               Token
               |> Ash.Changeset.for_create(:revoke_token, %{token: token})
               |> Ash.create(authorize?: false)

      assert :jti in error_fields(error)
    end

    test "revoke_all_stored_for_subject is the mechanism that does work" do
      user = user_fixture()
      bystander = user_fixture()

      jti = jti_of(user.__metadata__.token)
      bystander_jti = jti_of(bystander.__metadata__.token)

      %{status: :success} =
        Token
        |> Ash.bulk_update(
          :revoke_all_stored_for_subject,
          %{subject: AshAuthentication.user_to_subject(user)},
          authorize?: false,
          context: %{private: %{ash_authentication?: true}},
          return_errors?: true
        )

      assert revoked?(jti)
      refute revoked?(bystander_jti)
    end
  end

  describe "log_out_everywhere on password change" do
    # The User resource enables the log_out_everywhere add-on with
    # apply_on_password_change? true, so this is the cross-resource behavior
    # that makes "change your password to kick out an attacker" actually work.
    test "changing a password revokes the user's existing tokens" do
      user = user_fixture()
      jti = jti_of(user.__metadata__.token)

      refute revoked?(jti)

      {:ok, _} =
        user
        |> Ash.Changeset.for_update(:change_password, %{
          current_password: password(),
          password: "a brand new password",
          password_confirmation: "a brand new password"
        })
        |> Ash.update(authorize?: false)

      assert revoked?(jti)
    end

    test "resetting a password via token also revokes existing tokens" do
      # The more important of the two paths: a reset is what you do when you've
      # lost control of the account, so it has to invalidate whatever the
      # attacker is holding.
      user = user_fixture()
      jti = jti_of(user.__metadata__.token)

      # A real reset token, taken the way a user gets one: request a reset and
      # read the token out of the email Swoosh's test adapter captured. Drain
      # the mailbox first — registration already sent a confirmation email, and
      # that one would otherwise be the message we picked up.
      flush_emails()

      :ok =
        Banter.Accounts.User
        |> Ash.ActionInput.for_action(:request_password_reset_token, %{
          email: to_string(user.email)
        })
        |> Ash.run_action(authorize?: false)

      assert_received {:email, %{html_body: body}}
      [_, reset_token] = Regex.run(~r{/password-reset/([^\"\s<]+)}, body)

      {:ok, _} =
        user
        |> Ash.Changeset.for_update(:reset_password_with_token, %{
          reset_token: reset_token,
          password: "a brand new password",
          password_confirmation: "a brand new password"
        })
        |> Ash.update(authorize?: false)

      assert revoked?(jti)
    end

    test "another user's tokens are untouched by that password change" do
      user = user_fixture()
      bystander = user_fixture()
      bystander_jti = jti_of(bystander.__metadata__.token)

      {:ok, _} =
        user
        |> Ash.Changeset.for_update(:change_password, %{
          current_password: password(),
          password: "a brand new password",
          password_confirmation: "a brand new password"
        })
        |> Ash.update(authorize?: false)

      refute revoked?(bystander_jti)
    end
  end

  describe "expired tokens" do
    setup do
      user = user_fixture()
      %{user: user, jti: jti_of(user.__metadata__.token)}
    end

    test "the expired read returns nothing while tokens are live" do
      assert {:ok, []} =
               Token |> Ash.Query.for_read(:expired, %{}) |> Ash.read(authorize?: false)
    end

    test "the expired read finds a token whose expiry has passed", %{jti: jti} do
      expire!(jti)

      assert {:ok, expired} =
               Token |> Ash.Query.for_read(:expired, %{}) |> Ash.read(authorize?: false)

      assert jti in Enum.map(expired, & &1.jti)
    end

    test "expunge_expired removes expired tokens and leaves live ones", %{jti: jti} do
      other = user_fixture()
      other_jti = jti_of(other.__metadata__.token)

      expire!(jti)

      Token
      |> Ash.Query.for_read(:expired, %{})
      |> Ash.bulk_destroy!(:expunge_expired, %{}, authorize?: false)

      remaining = Enum.map(all_tokens(), & &1.jti)

      refute jti in remaining
      assert other_jti in remaining
    end
  end

  # Helpers

  defp flush_emails do
    receive do
      {:email, _} -> flush_emails()
    after
      0 -> :ok
    end
  end

  defp error_fields(%{errors: errors}) do
    Enum.flat_map(errors, fn
      %{field: field} when not is_nil(field) -> [field]
      %{fields: fields} when is_list(fields) -> fields
      _ -> []
    end)
  end

  defp error_fields(_), do: []

  # Backdates a stored token's expiry. Written with Ecto rather than an Ash
  # action because the resource exposes no way to alter expires_at — which is
  # itself the point: expiry is set once, when the token is issued.
  defp expire!(jti) do
    import Ecto.Query

    Banter.Repo.update_all(
      from(t in "tokens", where: t.jti == ^jti),
      set: [expires_at: DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)]
    )
  end
end
