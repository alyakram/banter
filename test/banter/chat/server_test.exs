defmodule Banter.Chat.ServerTest do
  use Banter.DataCase, async: true

  import Banter.Fixtures

  alias Banter.Chat
  alias Banter.Chat.Server

  defp create_server(attrs, opts) do
    Server
    |> Ash.Changeset.for_create(:create, attrs)
    |> Ash.create(opts)
  end

  describe "create" do
    test "a user can create a server they own" do
      user = user_fixture()

      assert {:ok, server} =
               create_server(%{name: "Test Server", owner_id: user.id}, actor: user)

      assert server.name == "Test Server"
      assert server.owner_id == user.id
    end

    test "generates an invite code" do
      user = user_fixture()

      assert {:ok, server} = create_server(%{name: "Coded", owner_id: user.id}, actor: user)

      assert is_binary(server.invite_code)
      assert String.length(server.invite_code) == 6
      assert server.invite_code == String.upcase(server.invite_code)
    end

    test "generates a distinct invite code per server" do
      user = user_fixture()

      codes =
        for _ <- 1..10 do
          server_fixture(user).invite_code
        end

      assert length(Enum.uniq(codes)) == 10
    end

    test "ignores a client-supplied invite code, since the attribute isn't writable" do
      user = user_fixture()

      assert {:error, error} =
               create_server(
                 %{name: "Sneaky", owner_id: user.id, invite_code: "CHOSEN"},
                 actor: user
               )

      # writable? false means it isn't an accepted input at all.
      assert %Ash.Error.Invalid{} = error
      refute_invite_code_taken("CHOSEN")
    end

    test "description and icon_url are optional" do
      user = user_fixture()

      assert {:ok, server} = create_server(%{name: "Bare", owner_id: user.id}, actor: user)
      assert server.description == nil
      assert server.icon_url == nil
    end

    test "accepts description and icon_url when given" do
      user = user_fixture()

      assert {:ok, server} =
               create_server(
                 %{
                   name: "Full",
                   description: "A described server",
                   icon_url: "/images/icon.png",
                   owner_id: user.id
                 },
                 actor: user
               )

      assert server.description == "A described server"
      assert server.icon_url == "/images/icon.png"
    end

    test "rejects a name shorter than 2 characters" do
      user = user_fixture()

      assert {:error, error} = create_server(%{name: "x", owner_id: user.id}, actor: user)
      assert :name in error_fields(error)
    end

    test "rejects a name longer than 100 characters" do
      user = user_fixture()

      assert {:error, error} =
               create_server(%{name: String.duplicate("a", 101), owner_id: user.id}, actor: user)

      assert :name in error_fields(error)
    end

    test "rejects a missing name" do
      user = user_fixture()

      assert {:error, error} = create_server(%{owner_id: user.id}, actor: user)
      assert :name in error_fields(error)
    end

    test "rejects a description longer than 1000 characters" do
      user = user_fixture()

      assert {:error, error} =
               create_server(
                 %{name: "Wordy", description: String.duplicate("a", 1001), owner_id: user.id},
                 actor: user
               )

      assert :description in error_fields(error)
    end

    test "requires the owner_id argument" do
      user = user_fixture()

      assert {:error, error} = create_server(%{name: "Ownerless"}, actor: user)
      assert :owner_id in error_fields(error)
    end

    test "is forbidden when creating a server owned by someone else" do
      user = user_fixture()
      other = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               create_server(%{name: "Not Mine", owner_id: other.id}, actor: user)
    end

    test "is forbidden with no actor" do
      user = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               create_server(%{name: "Anonymous", owner_id: user.id}, [])
    end

    test "the create_server code interface works and enforces the same policy" do
      user = user_fixture()
      other = user_fixture()

      assert {:ok, server} =
               Chat.create_server(%{name: "Via Interface", owner_id: user.id}, actor: user)

      assert server.owner_id == user.id

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.create_server(%{name: "Nope", owner_id: other.id}, actor: user)
    end
  end

  describe "read" do
    test "a member can read the server" do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:ok, [found]} = Ash.read(Server, actor: owner)
      assert found.id == server.id
    end

    test "a non-member reads nothing — the policy filters rather than raising" do
      owner = user_fixture()
      outsider = user_fixture()
      {_server, _} = server_with_owner_fixture(owner)

      assert {:ok, []} = Ash.read(Server, actor: outsider)
    end

    test "reading with no actor returns nothing" do
      owner = user_fixture()
      {_server, _} = server_with_owner_fixture(owner)

      assert {:ok, []} = Ash.read(Server)
    end

    test "the owner cannot read a server that has no membership row yet" do
      # Worth pinning explicitly: the read policy is membership-gated, and
      # creating a server does not create the owner's membership. The app
      # always joins the owner immediately afterwards (GuildServer does this),
      # so this only bites code that creates a server and reads it back without
      # joining. It fails closed, which is why it's documented rather than
      # "fixed" — loosening a read policy is not a change to make in passing.
      owner = user_fixture()
      server = server_fixture(owner)

      assert {:ok, []} = Ash.read(Server, actor: owner)
      assert {:error, %Ash.Error.Invalid{}} = Chat.get_server(server.id, actor: owner)
    end

    test "each member sees the server, and only servers they belong to" do
      owner = user_fixture()
      joiner = user_fixture()
      other_owner = user_fixture()

      {server, _} = server_with_owner_fixture(owner)
      member_fixture(joiner, server)
      {_unrelated, _} = server_with_owner_fixture(other_owner)

      assert {:ok, [found]} = Ash.read(Server, actor: joiner)
      assert found.id == server.id
    end
  end

  describe "by_id" do
    test "a member can fetch the server by id" do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:ok, found} = Chat.get_server(server.id, actor: owner)
      assert found.id == server.id
    end

    test "a non-member gets nothing back" do
      owner = user_fixture()
      outsider = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:error, %Ash.Error.Invalid{}} = Chat.get_server(server.id, actor: outsider)
    end

    test "no actor gets nothing back" do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:error, %Ash.Error.Invalid{}} = Chat.get_server(server.id)
    end
  end

  describe "by_invite_code" do
    # This action is deliberately bypassed in the policies block: the invite
    # code *is* the credential, so anyone holding one can look the server up
    # before deciding to join. These tests pin that intent — including that it
    # works with no actor, which is what makes an invite link usable.

    test "a non-member holding the code can look the server up" do
      owner = user_fixture()
      outsider = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:ok, found} = Chat.get_server_by_invite(server.invite_code, actor: outsider)
      assert found.id == server.id
    end

    test "works with no actor at all" do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:ok, found} = Chat.get_server_by_invite(server.invite_code)
      assert found.id == server.id
    end

    test "an unknown invite code finds nothing" do
      assert {:error, %Ash.Error.Invalid{}} = Chat.get_server_by_invite("NOSUCH")
    end

    test "the code must match exactly — it isn't a prefix or case-insensitive match" do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      assert {:error, _} = Chat.get_server_by_invite(String.downcase(server.invite_code))
      assert {:error, _} = Chat.get_server_by_invite(String.slice(server.invite_code, 0, 3))
    end
  end

  describe "update" do
    setup do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)
      %{owner: owner, server: server}
    end

    test "the owner can update name, description and icon_url", %{owner: owner, server: server} do
      assert {:ok, updated} =
               server
               |> Ash.Changeset.for_update(:update, %{
                 name: "Renamed",
                 description: "New description",
                 icon_url: "/images/new.png"
               })
               |> Ash.update(actor: owner)

      assert updated.name == "Renamed"
      assert updated.description == "New description"
      assert updated.icon_url == "/images/new.png"
    end

    test "a member who isn't the owner cannot update", %{server: server} do
      member = user_fixture()
      member_fixture(member, server)

      assert {:error, %Ash.Error.Forbidden{}} =
               server
               |> Ash.Changeset.for_update(:update, %{name: "Hijacked"})
               |> Ash.update(actor: member)
    end

    test "a non-member cannot update", %{server: server} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} =
               server
               |> Ash.Changeset.for_update(:update, %{name: "Hijacked"})
               |> Ash.update(actor: outsider)
    end

    test "no actor cannot update", %{server: server} do
      assert {:error, %Ash.Error.Forbidden{}} =
               server
               |> Ash.Changeset.for_update(:update, %{name: "Hijacked"})
               |> Ash.update()
    end

    test "name validations still apply on update", %{owner: owner, server: server} do
      assert {:error, error} =
               server
               |> Ash.Changeset.for_update(:update, %{name: "x"})
               |> Ash.update(actor: owner)

      assert :name in error_fields(error)
    end

    test "ownership cannot be transferred — owner_id isn't accepted", %{
      owner: owner,
      server: server
    } do
      other = user_fixture()

      assert {:error, %Ash.Error.Invalid{}} =
               server
               |> Ash.Changeset.for_update(:update, %{owner_id: other.id})
               |> Ash.update(actor: owner)
    end

    test "the invite code cannot be changed", %{owner: owner, server: server} do
      assert {:error, %Ash.Error.Invalid{}} =
               server
               |> Ash.Changeset.for_update(:update, %{invite_code: "NEWONE"})
               |> Ash.update(actor: owner)
    end
  end

  describe "destroy" do
    setup do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)
      %{owner: owner, server: server}
    end

    test "the owner can destroy the server, which archives rather than deletes it", %{
      owner: owner,
      server: server
    } do
      # AshArchival turns :destroy into a soft delete, so this returns the
      # archived record instead of a bare :ok, with archived_at stamped.
      assert {:ok, archived} = Ash.destroy(server, actor: owner)
      assert archived.archived_at
    end

    test "a destroyed server is no longer readable", %{owner: owner, server: server} do
      {:ok, _} = Ash.destroy(server, actor: owner)

      assert {:ok, []} = Ash.read(Server, actor: owner)
      assert {:error, %Ash.Error.Invalid{}} = Chat.get_server(server.id, actor: owner)
    end

    test "a destroyed server can't be found by its invite code either", %{
      owner: owner,
      server: server
    } do
      code = server.invite_code
      {:ok, _} = Ash.destroy(server, actor: owner)

      assert {:error, %Ash.Error.Invalid{}} = Chat.get_server_by_invite(code)
    end

    test "a member who isn't the owner cannot destroy", %{server: server} do
      member = user_fixture()
      member_fixture(member, server)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(server, actor: member)
    end

    test "a non-member cannot destroy", %{server: server} do
      outsider = user_fixture()

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(server, actor: outsider)
    end

    test "no actor cannot destroy", %{server: server} do
      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(server)
    end
  end

  describe "paper trail" do
    # The resource declares `paper_trail` tracking name/description/icon_url in
    # :changes_only mode, so version history is part of its configured
    # behavior, not incidental.

    test "an update records a version" do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      {:ok, _} =
        server
        |> Ash.Changeset.for_update(:update, %{name: "Renamed"})
        |> Ash.update(actor: owner)

      assert {:ok, versions} = Ash.read(Banter.Chat.Server.Version, authorize?: false)

      assert Enum.any?(versions, fn version ->
               version.version_source_id == server.id and version.name == "Renamed"
             end)
    end

    test "history accumulates across successive updates" do
      owner = user_fixture()
      {server, _} = server_with_owner_fixture(owner)

      server =
        Enum.reduce(["First", "Second", "Third"], server, fn name, acc ->
          {:ok, updated} =
            acc
            |> Ash.Changeset.for_update(:update, %{name: name})
            |> Ash.update(actor: owner)

          updated
        end)

      {:ok, versions} = Ash.read(Banter.Chat.Server.Version, authorize?: false)
      names = for v <- versions, v.version_source_id == server.id, do: v.name

      assert "First" in names
      assert "Second" in names
      assert "Third" in names
    end
  end

  # Helpers

  defp refute_invite_code_taken(code) do
    assert {:error, _} = Chat.get_server_by_invite(code)
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
