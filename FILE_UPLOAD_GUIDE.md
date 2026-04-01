# File Upload System - Implementation Guide
**Date:** February 8, 2026
**Feature:** Image file uploads for messages
**Storage:** Local filesystem (migration path to MinIO/S3)

---

## Table of Contents
- [Overview](#overview)
- [Architecture](#architecture)
- [Implementation Details](#implementation-details)
- [File Storage](#file-storage)
- [Database Schema](#database-schema)
- [LiveView Upload Flow](#liveview-upload-flow)
- [Static File Serving](#static-file-serving)
- [Usage Examples](#usage-examples)
- [Troubleshooting](#troubleshooting)
- [Future Migration](#future-migration)

---

## Overview

The Discord clone supports uploading image files as message attachments. Users can attach up to 10 images per message, with a maximum file size of 25 MB per image.

### Key Features
- **File Types:** Images only (.jpg, .jpeg, .png, .gif, .webp, .svg)
- **Max File Size:** 25 MB per image
- **Max Attachments:** 10 images per message
- **Storage:** Local filesystem at `priv/static/uploads/`
- **Upload Flow:** Synchronous - files uploaded before message is sent
- **Real-time:** Attachments broadcast via PubSub with messages

### Design Decisions
- **Local storage first:** Simple to implement, works for single-server deployments
- **Migration ready:** Code structured for easy migration to MinIO/S3
- **Hierarchical organization:** Files organized by server and channel
- **UUID filenames:** Prevents collisions and path traversal attacks

---

## Architecture

### Components

```
┌─────────────────────────────────────────────────────────────┐
│                         ChatLive                            │
│  (Phoenix LiveView with allow_upload configuration)         │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ 1. User selects images
                 │ 2. LiveView tracks uploads
                 │ 3. User clicks send
                 │
                 ▼
┌─────────────────────────────────────────────────────────────┐
│              consume_uploaded_entries                       │
│  (Processes each selected image)                            │
└────────────────┬───────────────────────────────────────────┘
                 │
                 │ For each image:
                 ▼
┌─────────────────────────────────────────────────────────────┐
│                   Storage.upload_file()                     │
│  • Generates UUID filename                                  │
│  • Creates directory structure                              │
│  • Copies file from temp to priv/static/uploads/           │
│  • Returns {storage_path, url}                              │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ Returns attachment data (map)
                 ▼
┌─────────────────────────────────────────────────────────────┐
│              Chat.create_message()                          │
│  • Creates Message record                                   │
│  • Creates Attachment records (manage_relationship)         │
│  • Associates attachments with message                      │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ Message with attachments
                 ▼
┌─────────────────────────────────────────────────────────────┐
│            GuildServer.send_message_with_attachments()      │
│  • Loads attachments relationship                           │
│  • Broadcasts via PubSub to guild topic                     │
└────────────────┬────────────────────────────────────────────┘
                 │
                 │ Broadcast to all subscribers
                 ▼
┌─────────────────────────────────────────────────────────────┐
│         ChatLive.handle_info (all connected users)          │
│  • Receives message_create event                            │
│  • Appends message to @messages                             │
│  • UI re-renders with images                                │
└─────────────────────────────────────────────────────────────┘
```

---

## Implementation Details

### 1. Storage Module

**File:** `lib/banter/storage.ex`

Handles all file system operations:

```elixir
defmodule Banter.Storage do
  @upload_dir "priv/static/uploads"

  @doc """
  Uploads a file to local filesystem storage.
  
  Returns {:ok, %{storage_path: path, url: url}} or {:error, reason}
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
    full_path |> Path.dirname() |> File.mkdir_p!()
    
    # Copy file to storage location
    case File.cp(file_path, full_path) do
      :ok ->
        url = build_url(storage_path)
        {:ok, %{storage_path: storage_path, url: url}}
      {:error, reason} ->
        {:error, :upload_failed}
    end
  end

  @doc "Deletes a file from local filesystem storage."
  def delete_file(storage_path)

  @doc "Ensures the upload directory exists (called on app startup)."
  def ensure_upload_directory()

  # Private helpers
  defp build_storage_path(server_id, channel_id, filename) do
    Path.join(["servers", server_id, "channels", channel_id, filename])
  end

  defp build_url(storage_path) do
    "/" <> Path.join("uploads", storage_path)
  end
end
```

**Key Points:**
- UUID filenames prevent collisions and security issues
- Hierarchical directory structure for organization
- Automatic directory creation
- Returns both storage path (for database) and URL (for serving)

### 2. Attachment Resource

**File:** `lib/banter/chat/attachment.ex`

Ash resource for file attachment metadata:

```elixir
defmodule Banter.Chat.Attachment do
  use Ash.Resource,
    otp_app: :banter,
    domain: Banter.Chat,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshArchival.Resource]

  attributes do
    uuid_v7_primary_key :id

    attribute :filename, :string do
      allow_nil? false
      constraints max_length: 255
    end

    attribute :size, :integer do
      allow_nil? false
      constraints min: 1, max: 25_000_000  # 25 MB max
    end

    attribute :content_type, :string do
      allow_nil? false
      constraints max_length: 100
    end

    attribute :storage_path, :string do
      allow_nil? false
      constraints max_length: 500
    end

    attribute :url, :string do
      allow_nil? false
      constraints max_length: 1000
    end

    attribute :width, :integer, allow_nil?: true
    attribute :height, :integer, allow_nil?: true

    timestamps()
  end

  relationships do
    belongs_to :message, Banter.Chat.Message do
      allow_nil? false
    end
  end

  validations do
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
    defaults [:read, :destroy]

    create :create do
      primary? true
      accept [:filename, :size, :content_type, :storage_path, :url, :width, :height]
    end

    read :by_message do
      argument :message_id, :uuid, allow_nil?: false
      filter expr(message_id == ^arg(:message_id))
      prepare build(sort: [inserted_at: :asc])
    end
  end
end
```

**Key Points:**
- Validates content type must be image/*
- Size constraint enforced at database level
- Soft delete via AshArchival
- `message_id` set automatically via relationship

### 3. Message Resource Updates

**File:** `lib/banter/chat/message.ex`

Added attachment support to messages:

```elixir
# Made content nullable
attribute :content, :string do
  allow_nil? true  # Messages can have only attachments
  constraints min_length: 1, max_length: 4000
end

# Added attachments relationship
has_many :attachments, Banter.Chat.Attachment do
  public? true
end

# Validation: must have content OR attachments
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

# Updated create action
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
```

**Key Changes:**
- Content is now optional (can send attachments without text)
- Added `:attachments` argument as array of maps
- `manage_relationship` with `type: :create` creates attachment records
- Validation ensures at least content OR attachments

### 4. LiveView Integration

**File:** `lib/banter_web/live/chat/chat_live.ex`

Upload configuration in mount:

```elixir
def mount(_params, _session, socket) do
  socket =
    socket
    # ... other assigns ...
    |> allow_upload(:attachments,
      accept: ~w(.jpg .jpeg .png .gif .webp .svg),
      max_entries: 10,
      max_file_size: 25_000_000,  # 25 MB
      auto_upload: false
    )

  {:ok, socket}
end
```

Handle message sending with uploads:

```elixir
def handle_event("send_message", %{"content" => content}, socket) do
  # Get current context
  server_id = socket.assigns.current_server.id
  channel_id = socket.assigns.current_channel.id
  user_id = socket.assigns.current_user.id

  # Check if has content or uploads
  has_content = content && String.trim(content) != ""
  has_uploads = length(socket.assigns.uploads.attachments.entries) > 0

  if has_content || has_uploads do
    # Process uploaded files
    attachment_data = 
      consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
        case Banter.Storage.upload_file(
          path,
          server_id,
          channel_id,
          entry.client_name,
          entry.client_type
        ) do
          {:ok, %{storage_path: storage_path, url: url}} ->
            {:ok, %{
              filename: entry.client_name,
              size: entry.client_size,
              content_type: entry.client_type,
              storage_path: storage_path,
              url: url
            }}
          {:error, _} ->
            {:postpone, :error}
        end
      end)

    # Send message with attachments
    case GuildServer.send_message_with_attachments(
      server_id,
      channel_id,
      user_id,
      content,
      attachment_data
    ) do
      {:ok, _message} ->
        {:noreply, assign(socket, :message_input, "")}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to send message")}
    end
  else
    {:noreply, socket}
  end
end

# Handle upload cancellation
def handle_event("cancel_upload", %{"ref" => ref}, socket) do
  {:noreply, cancel_upload(socket, :attachments, ref)}
end

# Validate form (allows LiveView to track file selections)
def handle_event("validate_message", _params, socket) do
  {:noreply, socket}
end
```

**Key Points:**
- `consume_uploaded_entries` processes each selected file
- Calls `Storage.upload_file` for each image
- Collects attachment data as array of maps
- Passes to GuildServer for message creation

### 5. UI Components

**File:** `lib/banter_web/live/chat/components.ex`

Message input with file upload button and preview:

```elixir
def message_input(assigns) do
  ~H"""
  <div class="px-4 pb-6 flex-shrink-0">
    <%!-- File upload preview area --%>
    <%= if @uploads.attachments.entries != [] do %>
      <div class="mb-2 bg-[#2a2a4a] rounded-lg p-3">
        <div class="flex items-center justify-between mb-2">
          <span class="text-xs font-semibold text-[#dcddde]">
            Attachments (<%= length(@uploads.attachments.entries) %>)
          </span>
        </div>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
          <%= for entry <- @uploads.attachments.entries do %>
            <.attachment_preview upload={@uploads.attachments} entry={entry} />
          <% end %>
        </div>
      </div>
    <% end %>

    <.form for={%{}} phx-submit="send_message" phx-change="validate_message" class="bg-[#2a2a4a] rounded-lg flex items-center px-4">
      <%!-- File upload button --%>
      <button
        type="button"
        onclick={"document.getElementById('#{@uploads.attachments.ref}').click()"}
        class="cursor-pointer text-[#72767d] hover:text-[#dcddde] transition-colors mr-3"
      >
        <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
        </svg>
      </button>
      <.live_file_input upload={@uploads.attachments} class="hidden" id={@uploads.attachments.ref} />

      <input
        type="text"
        name="content"
        value={@message_input}
        phx-change="update_message_input"
        placeholder={"Message ##{@channel.name}"}
        autocomplete="off"
        class="flex-1 bg-transparent border-none outline-none py-3 text-[15px] text-[#dcddde] placeholder-[#72767d] focus:ring-0"
      />
      <button type="submit">Send</button>
    </.form>

    <%!-- Upload errors --%>
    <%= for err <- upload_errors(@uploads.attachments) do %>
      <div class="mt-2 text-xs text-red-400">
        <%= error_to_string(err) %>
      </div>
    <% end %>
  </div>
  """
end
```

Attachment preview component:

```elixir
def attachment_preview(assigns) do
  ~H"""
  <div class="relative bg-[#1e1e38] rounded-lg overflow-hidden group">
    <%= if String.starts_with?(@entry.client_type, "image/") do %>
      <.live_img_preview entry={@entry} class="w-full h-24 object-cover" />
    <% end %>

    <button
      type="button"
      phx-click="cancel_upload"
      phx-value-ref={@entry.ref}
      class="absolute top-1 right-1 bg-red-500 hover:bg-red-600 text-white rounded-full w-5 h-5 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity"
    >
      ×
    </button>

    <div class="absolute bottom-0 left-0 right-0 bg-black/60 text-white text-xs p-1 truncate">
      <%= @entry.client_name %>
    </div>

    <div class="absolute bottom-0 left-0 h-1 bg-[#5865f2]" style={"width: #{@entry.progress}%"} />
  </div>
  """
end
```

Message attachment display:

```elixir
def message_attachments(assigns) do
  ~H"""
  <div class="mt-2 grid grid-cols-1 sm:grid-cols-2 gap-2 max-w-lg">
    <%= for attachment <- @attachments do %>
      <.attachment_display attachment={attachment} />
    <% end %>
  </div>
  """
end

def attachment_display(assigns) do
  ~H"""
  <a href={@attachment.url} target="_blank" class="block bg-[#2a2a4a] rounded-lg overflow-hidden hover:bg-[#35355a] transition-colors">
    <%= if is_image?(@attachment.content_type) do %>
      <img
        src={@attachment.url}
        alt={@attachment.filename}
        class="w-full max-h-64 object-cover"
        loading="lazy"
      />
      <div class="p-2 text-xs text-[#72767d] flex items-center justify-between">
        <span class="truncate"><%= @attachment.filename %></span>
        <span><%= format_file_size(@attachment.size) %></span>
      </div>
    <% end %>
  </a>
  """
end
```

---

## File Storage

### Directory Structure

```
priv/static/uploads/
└── servers/
    └── {server_id}/
        └── channels/
            └── {channel_id}/
                ├── {uuid1}.jpg
                ├── {uuid2}.png
                └── {uuid3}.gif
```

### Example Paths

**Storage Path (in database):**
```
servers/019c3439-d2a4-7183-a158-1b4b18ee5b03/channels/019c3450-1ecf-726e-b913-107a6f82ccbf/4752a193-d7e3-4900-87d7-438cde0dc2da.jpg
```

**Public URL:**
```
/uploads/servers/019c3439-d2a4-7183-a158-1b4b18ee5b03/channels/019c3450-1ecf-726e-b913-107a6f82ccbf/4752a193-d7e3-4900-87d7-438cde0dc2da.jpg
```

**Full Filesystem Path:**
```
/path/to/project/priv/static/uploads/servers/019c3439-d2a4-7183-a158-1b4b18ee5b03/channels/019c3450-1ecf-726e-b913-107a6f82ccbf/4752a193-d7e3-4900-87d7-438cde0dc2da.jpg
```

### Benefits of This Structure
1. **Organization:** Easy to browse and debug
2. **Scalability:** Can add server/channel quotas
3. **Cleanup:** Can delete entire server/channel directories
4. **Security:** Can apply different permissions per server
5. **Migration:** Easy to move to object storage (same structure)

---

## Database Schema

### Attachments Table

```sql
CREATE TABLE attachments (
  id UUID PRIMARY KEY,
  filename VARCHAR(255) NOT NULL,
  size INTEGER NOT NULL CHECK (size BETWEEN 1 AND 25000000),
  content_type VARCHAR(100) NOT NULL,
  storage_path VARCHAR(500) NOT NULL,
  url VARCHAR(1000) NOT NULL,
  width INTEGER,
  height INTEGER,
  message_id UUID NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  inserted_at TIMESTAMP NOT NULL,
  updated_at TIMESTAMP NOT NULL,
  archived_at TIMESTAMP
);

CREATE INDEX idx_attachments_message_id ON attachments(message_id);
```

### Key Relationships
- `attachments.message_id` → `messages.id` (CASCADE delete)
- One message can have many attachments (has_many)
- One attachment belongs to one message (belongs_to)

---

## LiveView Upload Flow

### 1. User Interaction
```
User clicks + button → File picker opens → User selects images
```

### 2. LiveView Tracking
```elixir
# Automatically tracked by Phoenix LiveView
@uploads.attachments.entries = [
  %Phoenix.LiveView.UploadEntry{
    ref: "phx-Fxyz123",
    client_name: "photo.jpg",
    client_size: 1024000,
    client_type: "image/jpeg",
    progress: 0,
    ...
  }
]
```

### 3. Preview Display
```
Component checks @uploads.attachments.entries
If not empty → Show preview area
For each entry → Render .attachment_preview component
```

### 4. Form Submission
```
User types message (optional) → Clicks send
handle_event("send_message") triggered
```

### 5. File Processing
```elixir
consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
  # path = temp file path from upload
  # entry = metadata (filename, size, type)
  
  # Upload to permanent storage
  Storage.upload_file(path, server_id, channel_id, entry.client_name, entry.client_type)
  
  # Returns attachment data map
  {:ok, %{filename:, size:, content_type:, storage_path:, url:}}
end)
```

### 6. Message Creation
```elixir
Chat.create_message(%{
  channel_id: channel_id,
  author_id: user_id,
  content: content,
  attachments: attachment_data  # Array of maps
})
```

### 7. Database Operations
```
1. INSERT INTO messages (...)
2. For each attachment: INSERT INTO attachments (..., message_id=message.id)
3. Ash manages the relationship automatically
```

### 8. Broadcast
```elixir
# Load attachments before broadcasting
message = Ash.load!(message, :attachments)

# Broadcast to all subscribed clients
Phoenix.PubSub.broadcast(
  Banter.PubSub,
  "guild:#{guild_id}",
  {:guild_event, {:message_create, message}}
)
```

### 9. Real-time Update
```
All ChatLive processes receive broadcast
→ Append message to @messages
→ UI re-renders with images
```

---

## Static File Serving

### Configuration

**File:** `lib/banter_web.ex`

```elixir
def static_paths do
  ~w(assets fonts images favicon.ico robots.txt uploads)
  #                                              ^^^^^^^ CRITICAL!
end
```

**File:** `lib/banter_web/endpoint.ex`

```elixir
# First plug - handles all static files
plug Plug.Static,
  at: "/",
  from: :banter,
  gzip: not code_reloading?,
  only: BanterWeb.static_paths(),  # Must include "uploads"
  raise_on_missing_only: code_reloading?

# Second plug - serves uploaded files
plug Plug.Static,
  at: "/uploads",
  from: {:banter, "priv/static/uploads"},
  gzip: false
```

### Why Two Plugs?

1. **First Plug:** Handles general static files with an `:only` whitelist
   - Prevents serving sensitive files
   - Checks if path is in `static_paths()`
   
2. **Second Plug:** Specifically serves uploaded files
   - No `:only` restriction (serves everything in uploads/)
   - Separate from built assets

### Request Flow

```
Request: GET /uploads/servers/abc/channels/def/image.jpg

1. First Plug.Static checks:
   - Path starts with "/" ✓
   - "uploads" in static_paths()? ✓
   - Passes to next plug

2. Second Plug.Static checks:
   - Path starts with "/uploads" ✓
   - File exists at priv/static/uploads/servers/abc/channels/def/image.jpg ✓
   - Serves file with correct Content-Type

3. Response: 200 OK with image data
```

---

## Usage Examples

### Creating a Message with Attachments

```elixir
# From LiveView (user uploads images)
def handle_event("send_message", %{"content" => content}, socket) do
  # Process uploads
  attachment_data = consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
    # ... upload logic ...
  end)

  # Create message
  GuildServer.send_message_with_attachments(
    server_id,
    channel_id,
    user_id,
    content,
    attachment_data
  )
end
```

### Loading Messages with Attachments

```elixir
# Load messages for a channel
{:ok, messages} = Chat.list_channel_messages(%{
  channel_id: channel_id,
  limit: 50
})

# Load attachments relationship
messages = Ash.load!(messages, [:author, :attachments])

# Now can access attachments
Enum.each(messages, fn message ->
  IO.inspect(message.attachments)  # List of Attachment structs
end)
```

### Manually Creating an Attachment

```elixir
# Upload file
{:ok, %{storage_path: path, url: url}} =
  Storage.upload_file(
    "/tmp/uploaded_file.jpg",
    server_id,
    channel_id,
    "photo.jpg",
    "image/jpeg"
  )

# Create attachment record
{:ok, attachment} = Chat.create_attachment(%{
  filename: "photo.jpg",
  size: 1024000,
  content_type: "image/jpeg",
  storage_path: path,
  url: url,
  message_id: message_id
})
```

### Deleting a Message with Attachments

```elixir
# Load message with attachments
{:ok, message} = Chat.get_message(%{id: message_id}, load: [:attachments])

# Delete files from filesystem
Enum.each(message.attachments, fn attachment ->
  Storage.delete_file(attachment.storage_path)
end)

# Delete message (cascades to attachments via ON DELETE CASCADE)
Chat.delete_message(message)
```

---

## Troubleshooting

### Issue: Images show as broken image icons

**Symptoms:**
- Images upload successfully
- Message shows attachment with filename
- Image tag shows broken icon

**Causes & Solutions:**

1. **"uploads" not in static_paths()**
   ```
   Error: Plug.Static.InvalidPathError: static file exists but is not in the :only list
   ```
   **Solution:** Add "uploads" to `static_paths()` in `lib/banter_web.ex`

2. **File doesn't exist on disk**
   ```bash
   # Check if file exists
   ls -la priv/static/uploads/servers/{server_id}/channels/{channel_id}/
   ```
   **Solution:** Verify Storage.upload_file completed successfully

3. **Wrong URL in database**
   ```sql
   -- Check attachment URLs
   SELECT url FROM attachments WHERE id = 'attachment-id';
   ```
   **Solution:** URL must start with `/uploads/` not just `uploads/`

### Issue: File upload returns error

**Symptoms:**
- User selects image
- Nothing happens or error message appears

**Causes & Solutions:**

1. **File too large (> 25 MB)**
   ```
   Error message: "File is too large (max 25MB)"
   ```
   **Solution:** User must select smaller file

2. **Wrong file type**
   ```
   Error message: "Only image files are allowed"
   ```
   **Solution:** User must select image file (.jpg, .png, etc.)

3. **Too many files (> 10)**
   ```
   Error message: "Too many files (max 10 images)"
   ```
   **Solution:** User must deselect some files

4. **Upload directory doesn't exist**
   ```elixir
   # Check in application.ex
   Banter.Storage.ensure_upload_directory()
   ```
   **Solution:** Ensure this is called on app startup

5. **Permission issues**
   ```bash
   # Check directory permissions
   ls -la priv/static/uploads/
   chmod 755 priv/static/uploads/
   ```
   **Solution:** Ensure Phoenix process can write to uploads/

### Issue: Attachments show as #Ash.NotLoaded

**Symptoms:**
```elixir
message.attachments
#=> #Ash.NotLoaded<:relationship, field: :attachments>
```

**Solution:**
```elixir
# ALWAYS load attachments when displaying messages
messages = Ash.load!(messages, [:author, :attachments])
```

### Issue: Multiple file uploads fail

**Symptoms:**
- First file uploads successfully
- Subsequent files fail

**Cause:** Error in consume_uploaded_entries loop

**Solution:**
```elixir
# Use {:postpone, :error} to stop processing on error
consume_uploaded_entries(socket, :attachments, fn %{path: path}, entry ->
  case Storage.upload_file(...) do
    {:ok, data} -> {:ok, data}
    {:error, _} -> {:postpone, :error}  # Stop processing
  end
end)
```

### Issue: Images not showing in real-time

**Symptoms:**
- Images show for sender immediately
- Other users don't see images

**Cause:** Attachments not loaded before broadcast

**Solution:**
```elixir
# In GuildServer.send_message_with_attachments
message = Ash.load!(message, :attachments)  # BEFORE broadcast
Phoenix.PubSub.broadcast(...)
```

---

## Future Migration

### Migration to MinIO/S3

The code is structured for easy migration to object storage:

#### 1. Update Storage Module

```elixir
defmodule Banter.Storage do
  def upload_file(file_path, server_id, channel_id, filename, content_type) do
    backend = Application.get_env(:banter, :storage_backend, :local)
    
    case backend do
      :local -> upload_to_local(...)
      :minio -> upload_to_minio(...)
      :s3 -> upload_to_s3(...)
    end
  end
  
  defp upload_to_minio(file_path, server_id, channel_id, filename, content_type) do
    # Use ExAws.S3 to upload to MinIO
    storage_path = build_storage_path(server_id, channel_id, filename)
    
    file_path
    |> ExAws.S3.Upload.stream_file()
    |> ExAws.S3.upload("discord-uploads", storage_path,
      acl: :public_read,
      content_type: content_type
    )
    |> ExAws.request()
    
    url = build_minio_url(storage_path)
    {:ok, %{storage_path: storage_path, url: url}}
  end
end
```

#### 2. Configuration

```elixir
# config/runtime.exs
config :banter,
  storage_backend: :minio  # or :s3

config :ex_aws,
  access_key_id: System.get_env("MINIO_ACCESS_KEY"),
  secret_access_key: System.get_env("MINIO_SECRET_KEY"),
  region: "us-east-1"

config :ex_aws, :s3,
  scheme: "http://",
  host: "minio.example.com",
  port: 9000
```

#### 3. Migration Script

```elixir
# Migrate existing files from local to MinIO
defmodule Banter.MigrateToMinIO do
  def run do
    # Get all attachments
    {:ok, attachments} = Chat.list_attachments()
    
    Enum.each(attachments, fn attachment ->
      local_path = Path.join("priv/static/uploads", attachment.storage_path)
      
      # Upload to MinIO
      {:ok, result} = Storage.upload_to_minio(
        local_path,
        # ... extract server_id, channel_id from storage_path
      )
      
      # Update attachment URL
      Chat.update_attachment(attachment, %{url: result.url})
      
      IO.puts("Migrated: #{attachment.filename}")
    end)
  end
end
```

#### 4. No Code Changes Needed

These files **do not** need changes:
- Attachment resource
- Message resource
- ChatLive
- UI components
- Database schema

Only `Storage` module needs backend abstraction!

---

## Best Practices

### Security
1. **Never trust user filenames** - Always generate UUIDs
2. **Validate content types** - Check MIME type from upload
3. **Enforce file size limits** - Both client and server side
4. **Use file extension whitelist** - Only allow known image types
5. **Sanitize paths** - Prevent directory traversal attacks

### Performance
1. **Lazy load images** - Use `loading="lazy"` attribute
2. **Generate thumbnails** - For faster preview display (future)
3. **Use CDN** - When migrating to cloud storage
4. **Implement cleanup** - Delete orphaned files periodically
5. **Monitor disk space** - Set up alerts for uploads directory

### User Experience
1. **Show upload progress** - Use entry.progress for progress bars
2. **Allow cancel** - Let users remove files before sending
3. **Validate early** - Check file size/type before upload
4. **Clear error messages** - Use error_to_string helper
5. **Preview images** - Use live_img_preview for thumbnails

---

## Related Documentation

- [CLAUDE.md](CLAUDE.md) - Main project guide
- [PROJECT_DOCUMENTATION_2026-02-06.md](PROJECT_DOCUMENTATION_2026-02-06.md) - Comprehensive project docs
- [Phoenix LiveView Uploads](https://hexdocs.pm/phoenix_live_view/uploads.html) - Official upload docs
- [Ash Framework](https://hexdocs.pm/ash/) - Ash documentation

---

**Last Updated:** 2026-02-08
**Status:** ✅ Implemented and working
**Next Steps:** Consider image optimization and cloud migration
