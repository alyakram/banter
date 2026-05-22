defmodule Banter.Chat.Message do
  @moduledoc """
  A Message in a channel.

  Messages are the core content unit. They belong to a channel and
  a user (author). Supports soft-delete via AshArchival and edit
  tracking via AshPaperTrail.
  """

  use Ash.Resource,
    otp_app: :banter,
    domain: Banter.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "messages"
    repo Banter.Repo

    references do
      reference :channel, on_delete: :delete
      reference :author, on_delete: :nilify
    end
  end

  paper_trail do
    attributes_as_attributes [:content]
    change_tracking_mode :changes_only
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :content, :string do
      allow_nil? true
      public? true
      constraints min_length: 1, max_length: 4000
    end

    attribute :edited_at, :utc_datetime_usec do
      allow_nil? true
      public? true
    end

    attribute :pinned, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :message_type, :atom do
      allow_nil? false
      public? true
      default :default
      constraints one_of: [:default, :system, :reply, :pin_notification]
    end

    # For reply threading — references another message
    attribute :reply_to_id, :uuid do
      allow_nil? true
      public? true
    end

    # Nonce for client-side deduplication
    attribute :nonce, :string do
      allow_nil? true
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :channel, Banter.Chat.Channel do
      allow_nil? false
      public? true
    end

    belongs_to :author, Banter.Accounts.User do
      allow_nil? true
      public? true
    end

    # Self-referential: the message this is replying to
    belongs_to :reply_to, Banter.Chat.Message do
      source_attribute :reply_to_id
      allow_nil? true
      public? true
      define_attribute? false
    end

    has_many :attachments, Banter.Chat.Attachment do
      public? true
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action(:create) do
      authorize_if always()
    end

    policy action([:update, :pin, :unpin]) do
      authorize_if expr(author_id == ^actor(:id))
    end

    policy action(:destroy) do
      authorize_if expr(author_id == ^actor(:id))
    end
  end

  validations do
    # Message must have either content or attachments
    validate fn changeset, _context ->
      content = Ash.Changeset.get_attribute(changeset, :content)
      attachments = Ash.Changeset.get_argument(changeset, :attachments)

      has_content = content && String.trim(content) != ""
      has_attachments = attachments && length(attachments) > 0

      if has_content || has_attachments do
        :ok
      else
        {:error, field: :content, message: "Message must have content or attachments"}
      end
    end
  end

  actions do
    default_accept [:content]

    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:content, :nonce, :message_type, :reply_to_id]

      argument :channel_id, :uuid, allow_nil?: false
      argument :author_id, :uuid, allow_nil?: false
      argument :attachments, {:array, :map}, allow_nil?: true, default: []

      change set_attribute(:channel_id, arg(:channel_id))
      change set_attribute(:author_id, arg(:author_id))
      change manage_relationship(:attachments, :attachments, type: :create)
    end

    update :update do
      primary? true
      accept [:content]
      require_atomic? false

      change fn changeset, _context ->
        if Ash.Changeset.changing_attribute?(changeset, :content) do
          Ash.Changeset.force_change_attribute(changeset, :edited_at, DateTime.utc_now())
        else
          changeset
        end
      end
    end

    update :pin do
      accept []
      change set_attribute(:pinned, true)
    end

    update :unpin do
      accept []
      change set_attribute(:pinned, false)
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_channel do
      argument :channel_id, :uuid, allow_nil?: false
      argument :before_id, :uuid, allow_nil?: true

      filter expr(
        channel_id == ^arg(:channel_id) and
          (is_nil(^arg(:before_id)) or id < ^arg(:before_id))
      )

      prepare build(sort: [id: :desc], limit: 51)
    end

    read :pinned_in_channel do
      argument :channel_id, :uuid, allow_nil?: false
      filter expr(channel_id == ^arg(:channel_id) and pinned == true)
      prepare build(sort: [inserted_at: :desc])
    end
  end
end
