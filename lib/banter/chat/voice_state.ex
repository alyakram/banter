defmodule Banter.Chat.VoiceState do
  @moduledoc """
  Tracks a user's active voice channel connection.

  VoiceState records are transient — created when a user joins a voice
  channel and destroyed when they leave. A user can only be in one
  voice channel at a time (enforced by unique identity on user_id).
  """

  use Ash.Resource,
    otp_app: :banter,
    domain: Banter.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "voice_states"
    repo Banter.Repo

    references do
      reference :user, on_delete: :delete
      reference :channel, on_delete: :delete
      reference :server, on_delete: :delete
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :self_mute, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :self_deaf, :boolean do
      allow_nil? false
      public? true
      default false
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Banter.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :channel, Banter.Chat.Channel do
      allow_nil? false
      public? true
    end

    belongs_to :server, Banter.Chat.Server do
      allow_nil? false
      public? true
    end
  end

  identities do
    # A user can only be in one voice channel at a time (globally)
    identity :unique_user_voice, [:user_id]
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if expr(exists(server.members, user_id == ^actor(:id)))
    end

    # Joining voice is always self-service, and only for a server the user
    # actually belongs to. Two separate policies (both must pass) rather than
    # one combined expr — attribute/relationship filters can't be used to
    # authorize creates (no persisted row yet to filter against), so the
    # membership half uses a custom check that resolves server_id off the
    # changeset directly.
    policy action_type(:create) do
      authorize_if expr(^actor(:id) == ^arg(:user_id))
    end

    policy action_type(:create) do
      authorize_if Banter.Chat.Checks.ActorIsServerMember
    end

    # Mute/deafen toggles and leaving are both self-only.
    policy action_type([:update, :destroy]) do
      authorize_if expr(user_id == ^actor(:id))
    end
  end

  actions do
    default_accept [:self_mute, :self_deaf]

    defaults [:read, :destroy]

    create :join do
      primary? true
      accept [:self_mute, :self_deaf]

      argument :user_id, :uuid, allow_nil?: false
      argument :channel_id, :uuid, allow_nil?: false
      argument :server_id, :uuid, allow_nil?: false

      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:channel_id, arg(:channel_id))
      change set_attribute(:server_id, arg(:server_id))
    end

    update :update do
      primary? true
      accept [:self_mute, :self_deaf]
    end

    read :by_channel do
      argument :channel_id, :uuid, allow_nil?: false
      filter expr(channel_id == ^arg(:channel_id))
    end

    read :by_server do
      argument :server_id, :uuid, allow_nil?: false
      filter expr(server_id == ^arg(:server_id))
    end

    read :by_user do
      argument :user_id, :uuid, allow_nil?: false
      get? true
      filter expr(user_id == ^arg(:user_id))
    end
  end
end
