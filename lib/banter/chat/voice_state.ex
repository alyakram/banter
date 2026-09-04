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

    custom_indexes do
      # user_id is already covered by voice_states_unique_user_voice_index.
      # by_channel and by_server each filter on these alone.
      index [:channel_id]
      index [:server_id]
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

    # Checked against the *channel's* server rather than the `server_id`
    # argument. channel_id arrives from the client while server_id comes from
    # the caller's current session, and trusting the claimed server_id let a
    # member of server A join a voice channel in server B by passing B's
    # channel with A's server_id — and Voice.Room is keyed purely on
    # channel_id, so that put them in another server's live audio.
    # See AUDIT_FINDINGS.md #33.
    policy action_type(:create) do
      authorize_if Banter.Chat.Checks.ActorIsChannelMember
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

      # channel_id and server_id arrive as independent arguments, so nothing
      # otherwise stops them describing two different servers. Every
      # membership-gated read filters on the stored server_id, so a mismatched
      # row would be filed under the wrong server's audience. Verify they agree
      # — and that the channel is actually a voice channel.
      validate fn changeset, _context ->
        channel_id = Ash.Changeset.get_argument(changeset, :channel_id)
        server_id = Ash.Changeset.get_argument(changeset, :server_id)

        case Ash.get(Banter.Chat.Channel, channel_id, authorize?: false) do
          {:ok, %{server_id: ^server_id, type: :voice}} ->
            :ok

          {:ok, %{server_id: ^server_id}} ->
            {:error, field: :channel_id, message: "is not a voice channel"}

          {:ok, _other_server} ->
            {:error, field: :server_id, message: "does not match the channel's server"}

          _ ->
            {:error, field: :channel_id, message: "does not exist"}
        end
      end
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
