defmodule Banter.Chat.MemberTest do
  use Banter.DataCase, async: true

  import Banter.Fixtures

  alias Banter.Chat
  alias Banter.Chat.Member

  defp join(attrs, opts) do
    Member
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(opts)
  end

  defp join_attrs(user, server, extra \\ %{}) do
    Map.merge(%{user_id: user.id, server_id: server.id}, extra)
  end

  describe "create — self-joining" do
    setup do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)
      %{owner: owner, server: server}
    end

    test "a user can join a server themselves", %{server: server} do
      joiner = user_fixture()

      assert {:ok, member} = join(join_attrs(joiner, server), actor: joiner)
      assert member.user_id == joiner.id
      assert member.server_id == server.id
    end

    test "role defaults to :member when omitted", %{server: server} do
      # This is the case ActorSelfJoinsAsMember exists for: `^arg(:role)` reads
      # nil when the client omits the field, even though the attribute still
      # gets its :member default. The check reads the post-default attribute
      # instead, so omitting role has to succeed — if this ever starts failing,
      # someone has swapped the check back to an arg-based expression.
      joiner = user_fixture()

      assert {:ok, member} = join(join_attrs(joiner, server), actor: joiner)
      assert member.role == :member
    end

    test "explicitly passing role: :member is allowed", %{server: server} do
      joiner = user_fixture()

      assert {:ok, member} = join(join_attrs(joiner, server, %{role: :member}), actor: joiner)
      assert member.role == :member
    end

    for role <- [:owner, :admin, :moderator] do
      test "joining with role #{inspect(role)} is forbidden", %{server: server} do
        joiner = user_fixture()

        assert {:error, %Ash.Error.Forbidden{}} =
                 join(join_attrs(joiner, server, %{role: unquote(role)}), actor: joiner)
      end
    end

    test "creating a membership for someone else is forbidden", %{server: server} do
      joiner = user_fixture()
      someone_else = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               join(join_attrs(someone_else, server), actor: joiner)
    end

    test "joining with no actor is forbidden", %{server: server} do
      joiner = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} = join(join_attrs(joiner, server), [])
    end

    test "a nickname can be set while joining", %{server: server} do
      joiner = user_fixture()

      assert {:ok, member} =
               join(join_attrs(joiner, server, %{nickname: "Ali"}), actor: joiner)

      assert member.nickname == "Ali"
    end

    test "rejects a nickname longer than 32 characters", %{server: server} do
      joiner = user_fixture()

      assert {:error, error} =
               join(join_attrs(joiner, server, %{nickname: String.duplicate("a", 33)}),
                 actor: joiner
               )

      assert :nickname in error_fields(error)
    end

    test "joined_at is stamped automatically and can't be supplied", %{server: server} do
      joiner = user_fixture()
      before = DateTime.utc_now()

      assert {:ok, member} = join(join_attrs(joiner, server), actor: joiner)
      assert member.joined_at
      assert DateTime.compare(member.joined_at, before) in [:gt, :eq]

      other = user_fixture()

      assert {:error, %Ash.Error.Invalid{}} =
               join(join_attrs(other, server, %{joined_at: ~U[2020-01-01 00:00:00.000000Z]}),
                 actor: other
               )
    end

    test "requires user_id and server_id", %{server: server} do
      joiner = user_fixture()

      assert {:error, e1} =
               Member |> Ash.Changeset.for_create(:create, %{server_id: server.id}) |> Ash.create(actor: joiner)

      assert :user_id in error_fields(e1)

      assert {:error, e2} =
               Member |> Ash.Changeset.for_create(:create, %{user_id: joiner.id}) |> Ash.create(actor: joiner)

      assert :server_id in error_fields(e2)
    end

    test "a user can't join the same server twice", %{server: server} do
      joiner = user_fixture()

      assert {:ok, _} = join(join_attrs(joiner, server), actor: joiner)
      assert {:error, error} = join(join_attrs(joiner, server), actor: joiner)

      assert Enum.any?(error_fields(error), &(&1 in [:user_id, :server_id]))
    end

    test "the join_server code interface enforces the same policy", %{server: server} do
      joiner = user_fixture()
      someone_else = user_fixture()

      assert {:ok, member} =
               Chat.join_server(%{user_id: joiner.id, server_id: server.id}, actor: joiner)

      assert member.role == :member

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.join_server(%{user_id: someone_else.id, server_id: server.id}, actor: joiner)
    end
  end

  describe "read" do
    setup do
      owner = user_fixture()
      {server, owner_membership} = server_with_owner_fixture(owner)
      %{owner: owner, server: server, owner_membership: owner_membership}
    end

    test "a member can read the memberships of a server they belong to", %{
      owner: owner,
      server: server
    } do
      joiner = user_fixture()
      member_fixture(joiner, server)

      assert {:ok, members} = Ash.read(Member, actor: owner)
      user_ids = Enum.map(members, & &1.user_id)

      assert owner.id in user_ids
      assert joiner.id in user_ids
    end

    test "a non-member reads nothing", %{server: _server} do
      outsider = user_fixture()

      assert {:ok, []} = Ash.read(Member, actor: outsider)
    end

    test "reading with no actor returns nothing" do
      assert {:ok, []} = Ash.read(Member)
    end

    test "memberships of servers you don't belong to stay hidden", %{owner: owner} do
      other_owner = user_fixture()
      {_other_server, _} = server_with_owner_fixture(other_owner)

      assert {:ok, members} = Ash.read(Member, actor: owner)
      refute other_owner.id in Enum.map(members, & &1.user_id)
    end
  end

  describe "by_server" do
    test "lists that server's members, oldest join first" do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      second = user_fixture()
      third = user_fixture()
      member_fixture(second, server)
      member_fixture(third, server)

      assert {:ok, members} = Chat.list_server_members(%{server_id: server.id}, actor: owner)
      assert Enum.map(members, & &1.user_id) == [owner.id, second.id, third.id]
    end

    test "a non-member gets nothing back" do
      owner = user_fixture()
      outsider = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:ok, []} = Chat.list_server_members(%{server_id: server.id}, actor: outsider)
    end
  end

  describe "by_user" do
    test "lists a user's own memberships" do
      user = user_fixture()
      {server_a, _} = server_with_owner_fixture(user)
      {server_b, _} = server_with_owner_fixture(user)

      assert {:ok, memberships} = Chat.list_user_memberships(%{user_id: user.id}, actor: user)
      server_ids = Enum.map(memberships, & &1.server_id)

      assert server_a.id in server_ids
      assert server_b.id in server_ids
    end

    test "only shows another user's memberships in servers you share" do
      # The read policy still applies on top of the by_user filter, so this
      # can't be used to enumerate what servers someone else is in.
      me = user_fixture()
      them = user_fixture()

      {shared, _} = server_with_owner_fixture(me)
      member_fixture(them, shared)

      {private, _} = server_with_owner_fixture(them)

      assert {:ok, memberships} = Chat.list_user_memberships(%{user_id: them.id}, actor: me)
      server_ids = Enum.map(memberships, & &1.server_id)

      assert shared.id in server_ids
      refute private.id in server_ids
    end
  end

  describe "by_user_and_server" do
    test "fetches a single membership" do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:ok, membership} =
               Member
               |> Ash.Query.for_read(:by_user_and_server, %{
                 user_id: owner.id,
                 server_id: server.id
               })
               |> Ash.read_one(actor: owner)

      assert membership.user_id == owner.id
      assert membership.server_id == server.id
    end

    test "returns nothing for a non-member actor" do
      owner = user_fixture()
      outsider = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:ok, nil} =
               Member
               |> Ash.Query.for_read(:by_user_and_server, %{
                 user_id: owner.id,
                 server_id: server.id
               })
               |> Ash.read_one(actor: outsider)
    end
  end

  describe "update" do
    setup do
      owner = user_fixture()
      {server, owner_membership} = server_with_owner_fixture(owner)
      joiner = user_fixture()
      joiner_membership = member_fixture(joiner, server)

      %{
        owner: owner,
        server: server,
        owner_membership: owner_membership,
        joiner: joiner,
        joiner_membership: joiner_membership
      }
    end

    test "a member can change their own nickname", %{
      joiner: joiner,
      joiner_membership: membership
    } do
      assert {:ok, updated} =
               membership
               |> Ash.Changeset.for_update(:update, %{nickname: "New Nickname"})
               |> Ash.update(actor: joiner)

      assert updated.nickname == "New Nickname"
    end

    test "nickname length is still validated on update", %{
      joiner: joiner,
      joiner_membership: membership
    } do
      assert {:error, error} =
               membership
               |> Ash.Changeset.for_update(:update, %{nickname: String.duplicate("a", 33)})
               |> Ash.update(actor: joiner)

      assert :nickname in error_fields(error)
    end

    test "a member cannot edit someone else's membership", %{
      owner: owner,
      joiner_membership: membership
    } do
      assert {:error, %Ash.Error.Forbidden{}} =
               membership
               |> Ash.Changeset.for_update(:update, %{nickname: "Renamed by owner"})
               |> Ash.update(actor: owner)
    end

    test "updating with no actor is forbidden", %{joiner_membership: membership} do
      assert {:error, %Ash.Error.Forbidden{}} =
               membership
               |> Ash.Changeset.for_update(:update, %{nickname: "Anonymous"})
               |> Ash.update()
    end

    test "a member cannot promote themselves out of :member", %{
      joiner: joiner,
      joiner_membership: membership
    } do
      # Create is carefully guarded by ActorSelfJoinsAsMember so nobody can
      # join as anything but :member. That guard is worthless if :role can then
      # be changed on update, since update is self-only — join as :member, then
      # promote yourself. Role changes belong in a dedicated, separately
      # authorized action.
      for role <- [:owner, :admin, :moderator] do
        assert {:error, error} =
                 membership
                 |> Ash.Changeset.for_update(:update, %{role: role})
                 |> Ash.update(actor: joiner)

        assert %Ash.Error.Invalid{} = error
      end

      {:ok, reloaded} = Ash.get(Member, membership.id, actor: joiner)
      assert reloaded.role == :member
    end
  end

  describe "destroy" do
    setup do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)
      joiner = user_fixture()
      membership = member_fixture(joiner, server)

      %{owner: owner, server: server, joiner: joiner, membership: membership}
    end

    test "a member can leave a server", %{joiner: joiner, membership: membership} do
      assert :ok = Ash.destroy(membership, actor: joiner)
    end

    test "leaving hard-deletes the row — Member has no archival extension", %{
      joiner: joiner,
      membership: membership,
      owner: owner,
      server: server
    } do
      :ok = Ash.destroy(membership, actor: joiner)

      assert {:ok, remaining} = Chat.list_server_members(%{server_id: server.id}, actor: owner)
      refute joiner.id in Enum.map(remaining, & &1.user_id)
    end

    test "leaving revokes the ability to read that server's members", %{
      joiner: joiner,
      membership: membership,
      server: server
    } do
      :ok = Ash.destroy(membership, actor: joiner)

      assert {:ok, []} = Chat.list_server_members(%{server_id: server.id}, actor: joiner)
    end

    test "the server owner cannot remove another member — there is no kick path", %{
      owner: owner,
      membership: membership
    } do
      # destroy is `user_id == ^actor(:id)`, i.e. self-only, so nobody can be
      # removed by anyone else — not even by the owner of the server. Kick/ban
      # is listed as an unimplemented feature in AUDIT_FINDINGS.md; this pins
      # that the authorization side of it genuinely isn't there yet.
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(membership, actor: owner)
    end

    test "a non-member cannot remove a membership", %{membership: membership} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(membership, actor: outsider)
    end

    test "no actor cannot remove a membership", %{membership: membership} do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(membership)
    end
  end

  # Helpers

  defp error_fields(%{errors: errors}) do
    Enum.flat_map(errors, fn
      %{field: field} when not is_nil(field) -> [field]
      %{fields: fields} when is_list(fields) -> fields
      _ -> []
    end)
  end

  defp error_fields(_), do: []
end
