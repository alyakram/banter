defmodule Banter.Chat.Member do
  @moduledoc """
  A Member represents a user's membership in a server.

  This is the join resource between User and Server. It tracks
  per-server information like nickname, role, and when they joined.
  """

  use Ash.Resource,
    otp_app: :banter,
    domain: Banter.Chat,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "members"
    repo Banter.Repo

    references do
      reference :user, on_delete: :delete
      reference :server, on_delete: :delete
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
      accept [:nickname, :role]
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
