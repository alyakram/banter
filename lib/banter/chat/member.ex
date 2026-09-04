defmodule Banter.Chat.Member do
  @moduledoc """
  A Member represents a user's membership in a server.

  This is the join resource between User and Server. It tracks
  per-server information like nickname, role, and when they joined.
  """

  use Ash.Resource,
    otp_app: :banter,
    domain: Banter.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "members"
    repo Banter.Repo

    references do
      reference :user, on_delete: :delete
      reference :server, on_delete: :delete
    end

    custom_indexes do
      # The unique (user_id, server_id) identity below already covers
      # by_user/by_user_and_server via its leftmost prefix on user_id, but
      # by_server filters on server_id alone — not a usable prefix of that
      # composite — so it needs its own index. Called on every server switch.
      index [:server_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :nickname, :string do
      allow_nil? true
      public? true
      constraints max_length: 32
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      default :member
      constraints one_of: [:owner, :admin, :moderator, :member]
    end

    attribute :joined_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
      writable? false
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Banter.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :server, Banter.Chat.Server do
      allow_nil? false
      public? true
    end
  end

  identities do
    # A user can only be a member of a server once
    identity :unique_user_per_server, [:user_id, :server_id]
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(exists(server.members, user_id == ^actor(:id)))
    end

    # Joining a server is always self-service — a user can only ever create
    # a membership row for themselves, and always with role :member (no
    # role-management UI exists yet to grant anything higher — see
    # AUDIT_FINDINGS.md).
    policy action_type(:create) do
      authorize_if Banter.Chat.Checks.ActorSelfJoinsAsMember
    end

    # No role-management UI exists yet (see AUDIT_FINDINGS.md), so update and
    # leave are both self-only for now.
    policy action_type([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  actions do
    default_accept [:nickname, :role]

    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:nickname, :role]

      argument :user_id, :uuid, allow_nil?: false
      argument :server_id, :uuid, allow_nil?: false

      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:server_id, arg(:server_id))
    end

    update :update do
      primary? true
      # Deliberately does NOT accept :role. This action is self-only (see the
      # update/destroy policy above), so accepting :role here would let anyone
      # join as :member and immediately promote themselves to :owner —
      # defeating ActorSelfJoinsAsMember, which exists precisely to stop a user
      # picking their own role. Granting a role needs its own action with its
      # own policy (an owner/admin check), added alongside role management.
      accept [:nickname]
    end

    read :by_server do
      argument :server_id, :uuid, allow_nil?: false
      filter expr(server_id == ^arg(:server_id))
      prepare build(sort: [joined_at: :asc])
    end

    read :by_user do
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
    end

    read :by_user_and_server do
      argument :user_id, :uuid, allow_nil?: false
      argument :server_id, :uuid, allow_nil?: false
      get? true
      filter expr(user_id == ^arg(:user_id) and server_id == ^arg(:server_id))
    end
  end
end
