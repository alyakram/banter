defmodule Banter.Chat do
  @moduledoc """
  The Chat domain.

  This domain contains all resources related to the core Discord-like
  chat functionality: servers, channels, members, and messages.
  """

  use Ash.Domain,
    otp_app: :banter

  resources do
    resource Banter.Chat.Server do
      define :create_server, action: :create
      define :list_servers, action: :read
      define :get_server, args: [:id], action: :by_id
      define :update_server, action: :update
      define :destroy_server, action: :destroy
      define :get_server_by_invite, args: [:invite_code], action: :by_invite_code
    end

    resource Banter.Chat.Channel do
      define :create_channel, action: :create
      define :list_channels, action: :read
      define :get_channel, args: [:id], action: :by_id
      define :list_server_channels, action: :by_server
      define :update_channel, action: :update
      define :destroy_channel, action: :destroy
    end

    resource Banter.Chat.Member do
      define :join_server, action: :create
      define :list_members, action: :read
      define :list_server_members, action: :by_server
      define :list_user_memberships, action: :by_user
      define :update_member, action: :update
      define :leave_server, action: :destroy
    end

    resource Banter.Chat.Message do
      define :send_message, action: :create
      define :list_messages, action: :read
      define :list_channel_messages, action: :by_channel
      define :get_message, args: [:id], action: :by_id
      define :edit_message, action: :update
      define :delete_message, action: :destroy
    end

    resource Banter.Chat.Attachment do
      define :create_attachment, action: :create
      define :list_attachments, action: :read
      define :get_attachment, args: [:id], action: :by_id
      define :list_message_attachments, args: [:message_id], action: :by_message
      define :update_attachment, action: :update
      define :delete_attachment, action: :destroy
    end

    resource Banter.Chat.VoiceState do
      define :join_voice_channel, action: :join
      define :list_all_voice_states, action: :read
      define :list_voice_states_by_channel, args: [:channel_id], action: :by_channel
      define :list_voice_states_by_server, args: [:server_id], action: :by_server
      define :get_user_voice_state, args: [:user_id], action: :by_user
      define :update_voice_state, action: :update
      define :leave_voice_channel, action: :destroy
    end

    resource Banter.Chat.Server.Version
    resource Banter.Chat.Message.Version
  end

  # Convenience functions for GuildServer

  @doc """
  Creates a message in a channel.
  Alias for send_message for clarity.
  """
  def create_message(attrs, opts \\ []), do: send_message(attrs, opts)

  @doc """
  Lists all channels for a given server.
  """
  def list_channels_for_server(server_id) do
    case list_server_channels(%{server_id: server_id}) do
      {:ok, channels} -> channels
      {:error, _} -> []
    end
  end

  @doc """
  Lists all members for a given server.
  """
  def list_members_for_server(server_id) do
    case list_server_members(%{server_id: server_id}) do
      {:ok, members} -> members
      {:error, _} -> []
    end
  end

  @doc """
  Lists all voice states for a given voice channel.
  """
  def list_voice_states_for_channel(channel_id) do
    case list_voice_states_by_channel(channel_id) do
      {:ok, states} -> states
      {:error, _} -> []
    end
  end

  @doc """
  Lists all voice states in a given server.
  """
  def list_voice_states_for_server(server_id) do
    case list_voice_states_by_server(server_id) do
      {:ok, states} -> states
      {:error, _} -> []
    end
  end
end
