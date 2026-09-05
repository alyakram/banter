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
  # into stored XSS the moment anyone opens its direct URL.
  @allowed_content_types %{
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/gif" => ".gif",
    "image/webp" => ".webp"
  }

  # How many leading bytes are needed to identify any of the formats above.
  # WebP is the longest: "RIFF", a 4-byte length, then "WEBP".
  @magic_byte_count 12

  @doc """
  The MIME types accepted for upload, sorted.

  `Banter.Chat.Attachment` validates against this same list, so the storage
  layer and the data layer can't drift apart on what's considered safe.
  """
  def allowed_content_types, do: @allowed_content_types |> Map.keys() |> Enum.sort()

  @doc "Whether `content_type` is an accepted upload MIME type."
  def allowed_content_type?(content_type), do: Map.has_key?(@allowed_content_types, content_type)

  @doc """
  The extension an accepted `content_type` is *written* under, e.g.
  `"image/jpeg"` → `".jpg"`. Returns `nil` for anything not accepted.

  This is the canonical choice for new files, not the only valid one: `.jpeg`
  is equally correct for a JPEG, and files written before this existed may use
  it. Code checking whether an existing path agrees with a recorded type should
  ask `MIME.type/1` — the same lookup `Plug.Static` uses to type the response —
  rather than comparing against this.
  """
  def extension_for(content_type), do: Map.get(@allowed_content_types, content_type)

  @doc """
  Detects a file's type from its leading bytes.

  Returns `{:ok, content_type}` for one of `allowed_content_types/0`, or
  `{:error, :unrecognized_content}` for anything else — including a file too
  short to identify.

  The client's declared type is not consulted. That's the point: every other
  signal about an upload (the declared MIME type, the filename, its extension)
  is attacker-chosen, and the bytes are not.
  """
  def detect_content_type(file_path) do
    case read_magic_bytes(file_path) do
      <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> -> {:ok, "image/png"}
      <<0xFF, 0xD8, 0xFF, _rest::binary>> -> {:ok, "image/jpeg"}
      <<"GIF87a", _rest::binary>> -> {:ok, "image/gif"}
      <<"GIF89a", _rest::binary>> -> {:ok, "image/gif"}
      <<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>> -> {:ok, "image/webp"}
      _ -> {:error, :unrecognized_content}
    end
  end

  @doc """
  Uploads a file to local filesystem storage.

  The file's type is determined by **sniffing its leading bytes**, not by
  trusting `content_type`. A caller can declare anything — `content_type`
  arrives as `entry.client_type` from the browser — so the declared value is
  used only as a cheap early reject, and the bytes decide what is actually
  stored. A file whose contents aren't one of `allowed_content_types/0` is
  refused however it was labelled.

  The stored extension follows the *detected* type, and the detected type is
  returned so the caller can record it rather than the claim. That matters
  because `Plug.Static` derives the response `Content-Type` from the stored
  extension: a file served as `image/png` should be a PNG.

  ## Parameters

  - `file_path`: Path to the temporary uploaded file
  - `server_id`: Server UUID (for directory organization)
  - `channel_id`: Channel UUID (for directory organization)
  - `filename`: Original filename from upload (retained for logging only)
  - `content_type`: MIME type declared by the client

  ## Returns

  `{:ok, %{storage_path: path, url: url, content_type: detected}}` or
  `{:error, reason}`.

  ## Examples

      iex> upload_file("/tmp/upload.jpg", server_id, channel_id, "photo.jpg", "image/jpeg")
      {:ok, %{
        storage_path: "servers/abc-123/channels/def-456/uuid-123.jpg",
        url: "/uploads/servers/abc-123/channels/def-456/uuid-123.jpg",
        content_type: "image/jpeg"
      }}
  """
  def upload_file(file_path, server_id, channel_id, filename, content_type) do
    with :ok <- check_declared_type(content_type, filename),
         {:ok, detected} <- check_actual_content(file_path, filename, content_type) do
      store_file(file_path, server_id, channel_id, detected)
    end
  end

  defp check_declared_type(content_type, filename) do
    if allowed_content_type?(content_type) do
      :ok
    else
      Logger.warning(
        "Rejected upload of #{inspect(filename)}: unsupported content type #{inspect(content_type)}"
      )

      {:error, :unsupported_content_type}
    end
  end

  defp check_actual_content(file_path, filename, declared) do
    case detect_content_type(file_path) do
      {:ok, detected} ->
        if detected != declared do
          # Not fatal — the bytes win, and they're a format we accept. Worth a
          # line in the log because it's either a browser being loose about
          # MIME types or somebody probing.
          Logger.info(
            "Upload of #{inspect(filename)} declared #{inspect(declared)} but is #{inspect(detected)}; storing as #{inspect(detected)}"
          )
        end

        {:ok, detected}

      {:error, :unrecognized_content} ->
        Logger.warning(
          "Rejected upload of #{inspect(filename)}: declared #{inspect(declared)} but contents are not a supported image"
        )

        {:error, :content_type_mismatch}
    end
  end

  defp read_magic_bytes(file_path) do
    case File.open(file_path, [:read, :binary], &IO.binread(&1, @magic_byte_count)) do
      {:ok, data} when is_binary(data) -> data
      # :eof for an empty file, {:error, _} for an unreadable one — neither
      # identifies as anything, which is the correct outcome.
      _ -> <<>>
    end
  end

  defp store_file(file_path, server_id, channel_id, content_type) do
    ext = Map.fetch!(@allowed_content_types, content_type)
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
        {:ok, %{storage_path: storage_path, url: url, content_type: content_type}}

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
