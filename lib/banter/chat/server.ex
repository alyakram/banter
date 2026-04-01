defmodule Banter.Chat.Server do
  @moduledoc """
  A Server (Discord calls them "guilds").

  This is the top-level organizational unit. Users create servers,
  invite others, and communicate through channels within the server.
  """

  use Ash.Resource,
    otp_app: :banter,
    domain: Banter.Chat,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "servers"
    repo Banter.Repo

    references do
      reference :owner, on_delete: :nilify
      reference :channels, on_delete: :delete
      reference :members, on_delete: :delete
    end
  end

  paper_trail do
    # Track changes to server name, description, etc.
    attributes_as_attributes [:name, :description, :icon_url]
    change_tracking_mode :changes_only
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 2, max_length: 100
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 1000
    end

    attribute :icon_url, :string do
      allow_nil? true
      public? true
    end

    attribute :invite_code, :string do
      allow_nil? false
      public? true
      # Will be auto-generated
      writable? false
    end

    timestamps()
  end

  relationships do
    belongs_to :owner, Banter.Accounts.User do
      allow_nil? false
      public? true
    end

    has_many :channels, Banter.Chat.Channel
    has_many :members, Banter.Chat.Member
  end

  identities do
    identity :unique_invite_code, [:invite_code]
  end

  actions do
    default_accept [:name, :description, :icon_url]

    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :description, :icon_url]

      argument :owner_id, :uuid, allow_nil?: false

      change set_attribute(:owner_id, arg(:owner_id))

      change fn changeset, _context ->
        # Generate a random invite code
        code =
          :crypto.strong_rand_bytes(4)
          |> Base.url_encode64(padding: false)
          |> String.slice(0, 6)
          |> String.upcase()

        Ash.Changeset.force_change_attribute(changeset, :invite_code, code)
      end
    end

    update :update do
      primary? true
      accept [:name, :description, :icon_url]
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_invite_code do
      argument :invite_code, :string, allow_nil?: false
      get? true
      filter expr(invite_code == ^arg(:invite_code))
    end
  end
end
