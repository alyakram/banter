defmodule Banter.Chat.Channel do
  @moduledoc """
  A Channel within a Server.

  Channels are where communication happens. Each server has multiple
  channels, and each channel has a type (text, voice, announcement).
  Every server gets a default #general channel on creation.
  """

  use Ash.Resource,
    otp_app: :banter,
    domain: Banter.Chat,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshArchival.Resource]

  postgres do
    table "channels"
    repo Banter.Repo

    references do
      reference :server, on_delete: :delete
      reference :messages, on_delete: :delete
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
    end

    attribute :type, :atom do
      allow_nil? false
      public? true
      default :text
      constraints one_of: [:text, :voice, :announcement]
    end

    attribute :topic, :string do
      allow_nil? true
      public? true
      constraints max_length: 1024
    end

    attribute :position, :integer do
      allow_nil? false
      public? true
      default 0
    end

    attribute :slowmode_seconds, :integer do
      allow_nil? false
      public? true
      default 0
      constraints min: 0, max: 21600
    end

    timestamps()
  end

  relationships do
    belongs_to :server, Banter.Chat.Server do
      allow_nil? false
      public? true
    end

    has_many :messages, Banter.Chat.Message
  end

  identities do
    # Channel names must be unique within a server
    identity :unique_name_per_server, [:name, :server_id]
  end

  actions do
    default_accept [:name, :type, :topic, :position, :slowmode_seconds]

    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:name, :type, :topic, :position, :slowmode_seconds]

      argument :server_id, :uuid, allow_nil?: false
      change set_attribute(:server_id, arg(:server_id))
    end

    update :update do
      primary? true
      accept [:name, :topic, :position, :slowmode_seconds]
    end

    read :by_id do
      argument :id, :uuid, allow_nil?: false
      get? true
      filter expr(id == ^arg(:id))
    end

    read :by_server do
      argument :server_id, :uuid, allow_nil?: false
      filter expr(server_id == ^arg(:server_id))
      prepare build(sort: [position: :asc, inserted_at: :asc])
    end
  end
end
