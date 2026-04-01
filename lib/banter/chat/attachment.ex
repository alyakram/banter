defmodule Banter.Chat.Attachment do
  @moduledoc """
  A file attachment belonging to a message.

  Attachments are stored in the local filesystem (priv/static/uploads/) and referenced
  by messages. Multiple attachments can belong to a single message.

  ## Storage Strategy

  Files are stored in a hierarchical directory structure:
  - priv/static/uploads/servers/{server_id}/channels/{channel_id}/{uuid}.{ext}

  ## Attributes

  - `filename`: Original filename uploaded by user
  - `size`: File size in bytes (max 25 MB)
  - `content_type`: MIME type (must be image/*)
  - `storage_path`: Relative path on filesystem
  - `url`: Public URL path for accessing the file
  - `width`, `height`: Image dimensions (optional)
  """

  use Ash.Resource,
    otp_app: :banter,
    domain: Banter.Chat,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshArchival.Resource]

  postgres do
    table "attachments"
    repo Banter.Repo

    references do
      reference :message, on_delete: :delete
    end
  end

  attributes do
    uuid_v7_primary_key :id

    # Original filename uploaded by user
    attribute :filename, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
    end

    # File size in bytes
    attribute :size, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 25_000_000  # 25 MB max
    end

    # MIME type (e.g., "image/png", "image/jpeg")
    attribute :content_type, :string do
      allow_nil? false
      public? true
      constraints max_length: 100
    end

    # Storage path relative to priv/static/uploads/
    # Example: "servers/abc-123/channels/def-456/uuid.png"
    attribute :storage_path, :string do
      allow_nil? false
      public? true
      constraints max_length: 500
    end

    # Full URL to access the file
    # Example: "/uploads/servers/abc-123/channels/def-456/uuid.png"
    attribute :url, :string do
      allow_nil? false
      public? true
      constraints max_length: 1000
    end

    # Image dimensions (null for non-images or if not yet extracted)
    attribute :width, :integer do
      allow_nil? true
      public? true
    end

    attribute :height, :integer do
      allow_nil? true
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :message, Banter.Chat.Message do
      allow_nil? false
      public? true
    end
  end

  validations do
    # Validate content type is an image
    validate fn changeset, _context ->
      content_type = Ash.Changeset.get_attribute(changeset, :content_type)

      if content_type && String.starts_with?(content_type, "image/") do
        :ok
      else
        {:error, field: :content_type, message: "must be an image type (image/*)"}
      end
    end
  end

  actions do
    default_accept [
      :filename,
      :size,
      :content_type,
      :storage_path,
      :url,
      :width,
      :height
    ]

    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :filename,
        :size,
        :content_type,
        :storage_path,
        :url,
        :width,
        :height
      ]
    end

    update :update do
      primary? true
      accept [:width, :height, :url]
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_message do
      argument :message_id, :uuid, allow_nil?: false
      filter expr(message_id == ^arg(:message_id))
      prepare build(sort: [inserted_at: :asc])
    end
  end

  code_interface do
    define :create, action: :create
    define :get_by_id, args: [:id], action: :by_id
    define :list_by_message, args: [:message_id], action: :by_message
    define :update, action: :update
    define :destroy, action: :destroy
  end
end
