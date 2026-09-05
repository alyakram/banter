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
  - `content_type`: MIME type (must be one of `Banter.Storage.allowed_content_types/0`)
  - `storage_path`: Relative path on filesystem
  - `url`: Public URL path for accessing the file
  - `width`, `height`: Image dimensions (optional)
  """

  use Ash.Resource,
    otp_app: :banter,
    domain: Banter.Chat,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshArchival.Resource]

  postgres do
    table "attachments"
    repo Banter.Repo

    references do
      reference :message, on_delete: :delete
    end

    custom_indexes do
      # Postgres doesn't auto-index FK columns; by_message filters on this.
      index [:message_id]
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

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    # An attachment inherits its message's audience: readable by members of the
    # server the message's channel belongs to, and mutable only by the person
    # who posted it. This resource previously had no authorizer at all, so
    # every action was open to anyone (AUDIT_FINDINGS.md #32).
    policy action_type(:read) do
      authorize_if expr(exists(message.channel.server.members, user_id == ^actor(:id)))
    end

    policy action_type([:update, :destroy]) do
      authorize_if expr(message.author_id == ^actor(:id))
    end

    # Creates are only reachable through Message's `manage_relationship` —
    # `message_id` isn't an accepted input, so an attachment can't be pointed
    # at a message on its own (there's a test pinning that). Authorization for
    # creating one is therefore the parent Message create's job, which is
    # itself gated on channel membership and self-authorship.
    policy action_type(:create) do
      authorize_if always()
    end
  end

  validations do
    # Content type must be one of the raster formats Banter.Storage accepts.
    #
    # Deliberately an allowlist rather than a `String.starts_with?("image/")`
    # prefix check: `image/svg+xml` satisfies that prefix, and SVG is XML that
    # can embed `<script>`. Attachments are served same-origin from /uploads,
    # so storing one is stored XSS. This is the last line of defense no matter
    # which call site creates the record.
    validate fn changeset, _context ->
      content_type = Ash.Changeset.get_attribute(changeset, :content_type)

      if Banter.Storage.allowed_content_type?(content_type) do
        :ok
      else
        {:error,
         field: :content_type,
         message: "must be one of: #{Enum.join(Banter.Storage.allowed_content_types(), ", ")}"}
      end
    end

    # ...and the file it points at must be stored under an extension that
    # resolves to that same type. Plug.Static decides the response
    # Content-Type from the extension on disk, so a record claiming image/png
    # while pointing at a .gif would be served as something other than what it
    # says it is — and what the UI decides to render it as.
    #
    # Asks MIME.type/1 rather than comparing against one canonical extension,
    # because that's the same lookup Plug.Static performs: ".jpeg" and ".jpg"
    # both resolve to image/jpeg and both are correct, and records predating
    # this validation may legitimately use either.
    validate fn changeset, _context ->
      content_type = Ash.Changeset.get_attribute(changeset, :content_type)
      storage_path = Ash.Changeset.get_attribute(changeset, :storage_path)

      cond do
        # The allowlist validation above already reports a missing/bad type.
        is_nil(content_type) or is_nil(storage_path) ->
          :ok

        served_as(storage_path) == content_type ->
          :ok

        true ->
          {:error,
           field: :storage_path,
           message:
             "would be served as #{served_as(storage_path)}, which doesn't match #{content_type}"}
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
      # The content_type validation above is an anonymous function, which Ash
      # can't run atomically — without this the action fails every call with
      # Ash.Error.Framework.MustBeAtomic. Same bug Message.pin/unpin had.
      # See AUDIT_FINDINGS.md #31.
      require_atomic? false
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

  # The Content-Type Plug.Static will send for a file at this path, derived the
  # same way Plug.Static derives it: from the extension.
  defp served_as(storage_path) do
    storage_path
    |> Path.extname()
    |> String.trim_leading(".")
    |> MIME.type()
  end
end
