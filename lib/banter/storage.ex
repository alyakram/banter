defmodule Banter.Storage do
  @moduledoc """
  File storage operations for attachments.

  This module handles storing and retrieving uploaded files. Currently implements
  local filesystem storage with a clear migration path to MinIO/S3 in the future.

  ## Storage Structure

  Files are organized by server and channel:

      priv/static/uploads/
        servers/{server_id}/
          channels/{channel_id}/
            {uuid}.{ext}

  ## URL Strategy

  Files are served via Phoenix static plug:
  - Development: /uploads/servers/{server_id}/channels/{channel_id}/{uuid}.ext
  - Production: Same path (can add CDN later)

  ## Future Migration

  This module is designed to easily support multiple backends (local, MinIO, S3).
  When migrating to MinIO, only this module needs to change - all other code
  remains the same.
  """

  require Logger

  @upload_dir "priv/static/uploads"

  @doc """
  Uploads a file to local filesystem storage.

  ## Parameters

  - `file_path`: Path to the temporary uploaded file
  - `server_id`: Server UUID (for directory organization)
  - `channel_id`: Channel UUID (for directory organization)
  - `filename`: Original filename from upload
  - `content_type`: MIME type of the file

  ## Returns

  `{:ok, %{storage_path: path, url: url}}` or `{:error, reason}`

  ## Examples

      iex> upload_file("/tmp/upload.jpg", server_id, channel_id, "photo.jpg", "image/jpeg")
      {:ok, %{
        storage_path: "servers/abc-123/channels/def-456/uuid-123.jpg",
        url: "/uploads/servers/abc-123/channels/def-456/uuid-123.jpg"
      }}
  """
  def upload_file(file_path, server_id, channel_id, filename, content_type) do
    # Generate unique filename with original extension
    ext = Path.extname(filename)
    uuid = Ash.UUID.generate()
    filename_unique = "#{uuid}#{ext}"

    # Build storage path
    storage_path = build_storage_path(server_id, channel_id, filename_unique)
    full_path = Path.join(@upload_dir, storage_path)

    # Ensure directory exists
    full_path
    |> Path.dirname()
    |> File.mkdir_p!()

    # Copy file to storage location
    case File.cp(file_path, full_path) do
      :ok ->
        url = build_url(storage_path)
        Logger.info("Uploaded file to: #{full_path}")
        {:ok, %{storage_path: storage_path, url: url}}

      {:error, reason} ->
        Logger.error("Failed to upload file: #{inspect(reason)}")
        {:error, :upload_failed}
    end
  end

  @doc """
  Deletes a file from local filesystem storage.

  ## Parameters

  - `storage_path`: Relative storage path (e.g., "servers/abc/channels/def/uuid.jpg")

  ## Returns

  `:ok` or `{:error, reason}`
  """
  def delete_file(storage_path) do
    full_path = Path.join(@upload_dir, storage_path)

    case File.rm(full_path) do
      :ok ->
        Logger.info("Deleted file: #{full_path}")
        :ok

      {:error, :enoent} ->
        # File doesn't exist - consider this success
        Logger.warning("File not found (already deleted?): #{full_path}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to delete file #{full_path}: #{inspect(reason)}")
        {:error, :delete_failed}
    end
  end

  @doc """
  Ensures the upload directory exists.

  Called during application startup to create the base uploads directory
  if it doesn't already exist.

  ## Returns

  `:ok` or `{:error, reason}`
  """
  def ensure_upload_directory do
    case File.mkdir_p(@upload_dir) do
      :ok ->
        Logger.info("Upload directory ready: #{@upload_dir}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to create upload directory: #{inspect(reason)}")
        {:error, :directory_creation_failed}
    end
  end

  # Private helpers

  defp build_storage_path(server_id, channel_id, filename) do
    Path.join(["servers", server_id, "channels", channel_id, filename])
  end

  defp build_url(storage_path) do
    "/" <> Path.join("uploads", storage_path)
  end
end
