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

  # Raster image formats only, each mapped to the extension it gets stored
  # under. SVG is deliberately absent: it's XML, it can carry `<script>`, and
  # these files are served same-origin out of /uploads — so a stored SVG turns
  # into stored XSS the moment anyone opens its direct URL. See
  # AUDIT_FINDINGS.md #8.
  @allowed_content_types %{
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/gif" => ".gif",
    "image/webp" => ".webp"
  }

  @doc """
  The MIME types accepted for upload, sorted.

  `Banter.Chat.Attachment` validates against this same list, so the storage
  layer and the data layer can't drift apart on what's considered safe.
  """
  def allowed_content_types, do: @allowed_content_types |> Map.keys() |> Enum.sort()

  @doc "Whether `content_type` is an accepted upload MIME type."
  def allowed_content_type?(content_type), do: Map.has_key?(@allowed_content_types, content_type)

  @doc """
  Uploads a file to local filesystem storage.

  Rejects any `content_type` outside `allowed_content_types/0`.

  The stored extension is derived from the (allowlisted) content type, **not**
  from the client-supplied filename — otherwise a caller could pick the
  extension the file is later served under, and Plug.Static derives the
  response `Content-Type` from exactly that extension.

  ## Parameters

  - `file_path`: Path to the temporary uploaded file
  - `server_id`: Server UUID (for directory organization)
  - `channel_id`: Channel UUID (for directory organization)
  - `filename`: Original filename from upload (retained for logging only)
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
    case Map.fetch(@allowed_content_types, content_type) do
      {:ok, ext} ->
        store_file(file_path, server_id, channel_id, ext)

      :error ->
        Logger.warning(
          "Rejected upload of #{inspect(filename)}: unsupported content type #{inspect(content_type)}"
        )

        {:error, :unsupported_content_type}
    end
  end

  defp store_file(file_path, server_id, channel_id, ext) do
    filename_unique = "#{Ash.UUID.generate()}#{ext}"

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
