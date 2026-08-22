# Discord Clone - Project Documentation
**Date:** February 6, 2026
**Framework:** Phoenix LiveView + Ash Framework 3.0
**Language:** Elixir

## Table of Contents
- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Core Features](#core-features)
- [Database Schema](#database-schema)
- [File Structure](#file-structure)
- [Key Components](#key-components)
- [Authentication & Authorization](#authentication--authorization)
- [Real-time Features](#real-time-features)
- [Gateway Protocol](#gateway-protocol)
- [User Presence & Status](#user-presence--status)
- [Setup & Configuration](#setup--configuration)

---

## Project Overview

A Discord-inspired real-time chat application built with Phoenix LiveView and the Ash Framework. The application features:
- Real-time messaging across servers and channels
- User presence tracking with custom availability statuses
- WebSocket-based Gateway protocol for external clients
- Guild (server) system with channels and members
- Role-based permissions (owner/admin/member)
- Authentication with email/password and token management

## Architecture

### Technology Stack
- **Backend Framework:** Phoenix 1.7 + LiveView
- **Data Layer:** Ash Framework 3.0 with PostgreSQL (via AshPostgres)
- **Authentication:** AshAuthentication with Bcrypt
- **Real-time:** Phoenix PubSub + Phoenix.Presence
- **Background Jobs:** Oban (via AshOban)
- **ID Generation:** UUID v7 (time-ordered UUIDs via Ash)

### Design Patterns
1. **Domain-Driven Design:** Two main domains - `Accounts` and `Chat`
2. **GenServer Processes:** For stateful guild and session management
3. **CRDT-based Presence:** Distributed presence tracking across nodes
4. **Event-Driven:** PubSub for real-time message broadcasting

---

## Core Features

### 1. Server (Guild) Management
- Create and join servers using invite codes
- Server ownership with admin capabilities
- Channel organization within servers
- Member role management (owner, admin, member)

### 2. Real-time Messaging
- Channel-based text messaging
- Message history with author information
- Real-time message delivery via PubSub
- Timestamp formatting (Today, Yesterday, etc.)

### 3. User Presence & Status
- **Online/Offline Tracking:** Phoenix.Presence CRDT
- **Custom Availability Statuses:**
  - Online (green)
  - Away (yellow)
  - Do Not Disturb (red)
  - Invisible (gray - user appears offline to others)
- **Status Persistence:** Stored in database, synced across sessions
- **Multi-connection Support:** Handles users with multiple tabs/devices

### 4. WebSocket Gateway
- Discord-compatible gateway protocol
- Session management with heartbeat mechanism
- IDENTIFY and RESUME flows
- Zombie session detection and cleanup
- Event dispatching (READY, MESSAGE_CREATE, etc.)

### 5. Authentication & Security
- Email/password authentication with Bcrypt
- JWT token-based sessions
- Password reset flow with email tokens
- Email confirmation system
- Actor-based authorization policies

---

## Database Schema

### Users Table
```elixir
- id: uuid (primary key)
- email: cistring (unique)
- hashed_password: string (sensitive)
- confirmed_at: utc_datetime_usec
- availability: atom (:online, :away, :dnd, :invisible)
```

### Servers Table
```elixir
- id: uuid (UUID v7 - time-ordered)
- name: string
- owner_id: uuid (references users)
- invite_code: string (unique, 8 chars)
- inserted_at: utc_datetime_usec
```

### Channels Table
```elixir
- id: uuid (UUID v7 - time-ordered)
- name: string
- server_id: uuid (references servers)
- inserted_at: utc_datetime_usec
```

### Messages Table
```elixir
- id: uuid (UUID v7 - time-ordered)
- content: string
- channel_id: uuid (references channels)
- author_id: uuid (references users)
- inserted_at: utc_datetime_usec
```

### Memberships Table
```elixir
- id: uuid (primary key)
- user_id: uuid (references users)
- server_id: uuid (references servers)
- role: atom (:owner, :admin, :member)
- nickname: string (optional)
- joined_at: utc_datetime_usec
```

### Tokens Table
```elixir
- id: uuid (primary key)
- subject: string
- jti: string
- token: string (hashed)
- purpose: string
- expires_at: utc_datetime_usec
```

---

## File Structure

### Core Application Files

```
lib/
├── banter/
│   ├── application.ex              # OTP application supervisor
│   ├── repo.ex                     # Ecto repository
│   ├── snowflake.ex                # Snowflake ID generator (unused - UUIDs used instead)
│   ├── secrets.ex                  # JWT signing secrets
│   │
│   ├── accounts/                   # Accounts domain
│   │   ├── user.ex                 # User resource with auth
│   │   └── token.ex                # Authentication tokens
│   ├── accounts.ex                 # Accounts domain definition
│   │
│   ├── chat/                       # Chat domain
│   │   ├── server.ex               # Server (guild) resource
│   │   ├── channel.ex              # Channel resource
│   │   ├── message.ex              # Message resource
│   │   └── membership.ex           # Server membership resource
│   ├── chat.ex                     # Chat domain definition
│   │
│   ├── gateway.ex                  # Gateway protocol helpers
│   ├── guild_server.ex             # Guild GenServer process
│   └── session.ex                  # Gateway session GenServer
│
├── banter_web/
│   ├── endpoint.ex                 # Phoenix endpoint
│   ├── router.ex                   # Route definitions
│   ├── presence.ex                 # Phoenix.Presence for online users
│   ├── auth_overrides.ex           # AshAuthentication UI overrides
│   ├── live_user_auth.ex           # LiveView authentication
│   │
│   ├── controllers/
│   │   └── auth_controller.ex      # Auth callback controller
│   │
│   ├── live/
│   │   ├── chat_live.ex            # Main chat interface
│   │   └── gateway_live.ex         # WebSocket gateway
│   │
│   └── components/
│       ├── layouts.ex              # Layout components
│       └── layouts/
│           └── root.html.heex      # Root layout template
│
└── assets/
    ├── css/app.css                 # Tailwind CSS styles
    └── js/
        ├── app.js                  # Main JavaScript
        └── hooks.js                # LiveView hooks
```

### Configuration Files

```
config/
├── config.exs                      # Base configuration
├── dev.exs                         # Development config
├── test.exs                        # Test config
└── runtime.exs                     # Runtime configuration

priv/repo/migrations/               # Database migrations
```

---

## Key Components

### 1. ChatLive (`lib/banter_web/live/chat_live.ex`)
**Purpose:** Main chat interface LiveView

**Responsibilities:**
- Server and channel navigation
- Real-time message display and sending
- Member list with online status indicators
- User status management (online/away/dnd/invisible)
- Modal management (create server, join server, create channel)

**Key Features:**
- Automatic presence tracking on mount
- PubSub subscriptions for real-time updates
- Status dropdown with color-coded indicators
- Responsive UI with Tailwind CSS

**Socket Assigns:**
```elixir
- servers: list of user's servers
- current_server: selected server
- channels: channels in current server
- current_channel: selected channel
- messages: messages in current channel
- members: members of current server
- online_users: list of online user IDs
- current_user: authenticated user
- show_status_menu: boolean for status dropdown
```

### 2. GuildServer (`lib/banter/guild_server.ex`)
**Purpose:** GenServer managing individual guild state

**Responsibilities:**
- Channel CRUD operations
- Member management
- Message broadcasting via PubSub
- Invite code generation and validation

**State:**
```elixir
- guild_id: server ID
- channels: list of channels
- members: list of memberships
```

**Key Operations:**
- `create_channel/2` - Creates a new channel
- `send_message/2` - Broadcasts message to channel subscribers
- `add_member/2` - Adds user to server via invite code
- `list_channels/1` - Returns all channels
- `list_members/1` - Returns all members

### 3. Session (`lib/banter/session.ex`)
**Purpose:** GenServer managing WebSocket gateway sessions

**Responsibilities:**
- Gateway protocol implementation (HELLO, IDENTIFY, RESUME)
- Heartbeat monitoring and zombie detection
- Event dispatching to clients
- Presence tracking for gateway connections

**Session States:**
- `:waiting_identify` - Initial state, awaiting IDENTIFY
- `:identified` - Active session
- `:zombie` - Missed heartbeat, awaiting reconnect

**Heartbeat Configuration:**
```elixir
@heartbeat_interval 45_000   # 45 seconds
@heartbeat_timeout 60_000    # 60 seconds grace period
@zombie_timeout 180_000      # 3 minutes before cleanup
```

### 4. Presence (`lib/banter_web/presence.ex`)
**Purpose:** Phoenix.Presence module for distributed online status

**Key Functions:**
- `online_user_ids/0` - Returns list of online users (excludes invisible)
- `user_online?/1` - Checks if specific user is online
- `get_user_presence/1` - Gets presence metadata for user
- `update_status/3` - Updates user's status metadata

**Presence Metadata:**
```elixir
%{
  online_at: unix_timestamp,
  status: :online | :away | :dnd | :invisible,
  email: user_email,
  session_id: optional_session_id
}
```

**Important:** Status is now read from database (source of truth), not Presence metadata, to handle multi-connection scenarios correctly.

### 5. Gateway Protocol (`lib/banter/gateway.ex`)
**Purpose:** Helper functions for Discord-compatible gateway events

**Event Types:**
- `HELLO` - Initial handshake with heartbeat interval
- `READY` - Session established successfully
- `RESUMED` - Session resumed after disconnect
- `HEARTBEAT_ACK` - Acknowledgment of client heartbeat
- `MESSAGE_CREATE` - New message event
- `CHANNEL_CREATE` - New channel event
- `GUILD_MEMBER_ADD` - New member joined

**Payload Format:**
```elixir
%{
  op: opcode,
  t: event_name,
  s: sequence_number,
  d: data
}
```

---

## Authentication & Authorization

### Authentication Flow
1. User registers with email/password
2. Password hashed with Bcrypt
3. Email confirmation token sent (optional)
4. User signs in to receive JWT token
5. Token stored in session and validated on requests

### Authorization Policies

#### User Resource Policies
```elixir
# Allow all authentication-related actions
bypass AshAuthentication.Checks.AshAuthenticationInteraction

# Anyone can read users
policy action(:read) do
  authorize_if always()
end

# Users can only update their own availability
policy action(:update_availability) do
  authorize_if expr(id == ^actor(:id))
end
```

#### Server/Channel Policies
```elixir
# Only server owners can create channels
policy action(:create_channel) do
  authorize_if relates_to_actor_via(:owner_id)
end

# Members can send messages in their servers
policy action(:send_message) do
  authorize_if actor_is_member()
end
```

### Token Management
- **Token Storage:** All tokens stored in database
- **Signing Secret:** Retrieved from `Banter.Secrets`
- **Token Purposes:** authentication, password_reset, confirmation
- **Expiration:** Configurable per token type

---

## Real-time Features

### PubSub Topics

#### Guild Events
```elixir
"guild:#{guild_id}"
```
**Events:**
- `{:message_create, message}` - New message
- `{:channel_create, channel}` - New channel
- `{:member_join, member}` - New member

#### Presence Updates
```elixir
"users:online"
```
**Events:**
- `presence_diff` - User connected/disconnected or status changed

### Message Broadcasting Flow
1. User sends message via ChatLive
2. Message created in database via Ash
3. GuildServer broadcasts to `"guild:#{guild_id}"` topic
4. All subscribed LiveView processes receive message
5. ChatLive appends message if in same channel

### Presence Tracking Flow
1. User connects to ChatLive
2. LiveView process calls `Presence.track/4`
3. Presence broadcasts `presence_diff` to `"users:online"`
4. All ChatLive processes update their `@online_users` list
5. UI updates member status indicators

---

## Gateway Protocol

### Connection Flow
```
Client                          Server
  |                               |
  |--- WebSocket Connect -------->|
  |<------ HELLO (op: 10) --------|
  |                               |
  |--- IDENTIFY (op: 2) --------->|
  |<------ READY (op: 0) ---------|
  |                               |
  |--- HEARTBEAT (op: 1) -------->|
  |<-- HEARTBEAT_ACK (op: 11) ----|
  |                               |
  |<-- Dispatch Events (op: 0) ---|
  |                               |
```

### Opcode Reference
```elixir
0  - Dispatch (server -> client events)
1  - Heartbeat (client -> server)
2  - Identify (client -> server)
6  - Resume (client -> server)
7  - Reconnect (server -> client)
9  - Invalid Session (server -> client)
10 - Hello (server -> client)
11 - Heartbeat ACK (server -> client)
```

### IDENTIFY Payload
```json
{
  "op": 2,
  "d": {
    "token": "user_jwt_token",
    "guild_ids": ["guild1", "guild2"]
  }
}
```

### RESUME Payload
```json
{
  "op": 6,
  "d": {
    "token": "user_jwt_token",
    "session_id": "session_uuid",
    "seq": 42
  }
}
```

---

## User Presence & Status

### Status System Architecture

**Design Decision:** User status (online/away/dnd/invisible) is a **user-level preference**, not a connection-level state.

**Source of Truth:** Database (`users.availability` field)

**Why Not Presence Metadata?**
- Presence is per-connection (one meta per browser tab/device)
- Status should be consistent across all user's connections
- Changing status in one tab should affect all tabs
- Invisible users should be hidden regardless of connection count

### Status Update Flow
1. User clicks status in dropdown menu
2. ChatLive `change_status` event handler triggered
3. Database updated: `Ash.Changeset.for_update(:update_availability, %{availability: status})`
4. Presence metadata updated (informational only): `Presence.update/3`
5. Socket assigns updated: `assign(:current_user, updated_user)`
6. UI re-renders with new status

### Status Display Logic

**For Current User (Bottom Left):**
- Read from `@current_user.availability`
- Always shows accurate status
- Color-coded text and indicator

**For Members List (Right Sidebar):**
```elixir
def user_status(user_id, online_users) do
  if user_id in online_users do
    # User is connected - read status from database
    case Ash.get(User, user_id) do
      {:ok, user} -> user.availability || :online
      _ -> :online  # Fallback
    end
  else
    # User is not connected
    :offline
  end
end
```

**For Online Users Filter:**
```elixir
def online_user_ids do
  "users:online"
  |> Presence.list()
  |> Enum.filter(fn {user_id, _} ->
    # Filter out invisible users by checking database
    case Ash.get(User, user_id) do
      {:ok, user} -> user.availability != :invisible
      _ -> true
    end
  end)
  |> Enum.map(fn {user_id, _} -> user_id end)
end
```

### Status Colors
```elixir
:online    -> "bg-[#3ba55c]"  # Green
:away      -> "bg-[#faa61a]"  # Yellow/Orange
:dnd       -> "bg-[#f04747]"  # Red
:invisible -> "bg-[#747f8d]"  # Gray
:offline   -> "bg-[#747f8d]"  # Gray
```

### Multi-Connection Handling
- Each browser tab/device creates separate Presence entry
- Multiple entries create multiple "metas" for same user_id
- Status change updates database once
- All connections read from same database source
- Ensures consistency across all user's devices

---

## Setup & Configuration

### Prerequisites
- Elixir 1.14+
- Erlang/OTP 25+
- PostgreSQL 14+
- Node.js 18+ (for assets)

### Environment Variables
```bash
DATABASE_URL="postgresql://user:pass@localhost/banter_dev"
SECRET_KEY_BASE="generated_secret_key"
PHX_HOST="localhost"
PORT="4000"
```

### Initial Setup
```bash
# Install dependencies
mix deps.get
cd assets && npm install && cd ..

# Create and migrate database
mix ecto.create
mix ecto.migrate

# Start server
mix phx.server
```

### Database Migrations
All migrations located in `priv/repo/migrations/`

Key migrations:
- `*_add_oban.exs` - Oban tables for background jobs
- `*_initialize_and_add_authentication_resources.exs` - Users and tokens
- `*_add_chat_resources.exs` - Servers, channels, messages, memberships
- `*_add_user_availability.exs` - User status field

### Running Migrations
```bash
# Run all pending migrations
mix ecto.migrate

# Rollback last migration
mix ecto.rollback

# Reset database (dev only)
mix ecto.reset
```

---

## Development Workflows

### Creating a New Server
1. User clicks "+" button in server sidebar
2. Modal appears with server name input
3. User enters name and submits
4. ChatLive calls `Chat.create_server/1`
5. Server created with unique invite code
6. User automatically added as owner
7. Default "general" channel created
8. UI updates to show new server

### Joining a Server
1. User clicks "Join Server" button
2. Modal appears with invite code input
3. User enters 8-character code
4. ChatLive calls `GuildServer.add_member/2`
5. Membership created in database
6. User added to server's member list
7. PubSub broadcasts member join event
8. UI updates to show new server

### Sending a Message
1. User types message in input field
2. User presses Enter or clicks send
3. ChatLive calls `Chat.send_message/1`
4. Message stored in database with UUID v7 ID
5. GuildServer broadcasts to guild topic
6. All subscribers receive message
7. ChatLive processes receive and display message
8. UI scrolls to latest message

### Changing Status
1. User clicks current status in bottom left
2. Dropdown menu appears with 4 options
3. User selects new status
4. ChatLive calls `Ash.Changeset.for_update(:update_availability, ...)`
5. Database updated with new status
6. Presence metadata updated
7. presence_diff event fires
8. All connected clients update online_users list
9. Member indicators update with new color
10. Menu closes automatically

---

## Performance Considerations

### Database Queries
- **N+1 Prevention:** Use `Ash.load/2` for associations
- **Pagination:** Messages should be paginated (TODO)
- **Indexes:** Added on foreign keys and frequently queried fields

### Presence Optimization
- **Database Reads:** `online_user_ids/0` reads DB for each user (can be cached)
- **Potential Improvement:** Cache user availability with TTL
- **CRDT Benefits:** Presence handles network partitions automatically

### GenServer Processes
- **Guild Per Server:** One GuildServer process per active server
- **Session Per Connection:** One Session process per gateway connection
- **Automatic Cleanup:** Processes terminate when unused
- **Registry:** Fast lookup via Registry instead of named processes

### PubSub Topics
- **Guild-specific:** Isolated topics prevent unnecessary broadcasts
- **Presence Topic:** Single global topic for all presence updates
- **Subscriber Count:** Each LiveView/Session subscribes individually

---

## Testing

### Test Configuration
See `config/test.exs` for test-specific settings.

### Running Tests
```bash
# Run all tests
mix test

# Run specific test file
mix test test/banter_web/controllers/error_html_test.exs

# Run with coverage
mix test --cover
```

### Test Database
Separate database used for testing: `banter_test`

---

## Known Limitations & TODOs

### Current Limitations
1. **No Message Pagination:** All messages loaded at once
2. **No File Uploads:** Text-only messages
3. **No Voice/Video:** Chat only
4. **No Direct Messages:** Server/channel based only
5. **Basic Permissions:** Simple owner/admin/member roles
6. **No Message Editing/Deletion:** Messages are immutable
7. **No Server Settings:** Limited customization options
8. **No User Profiles:** Minimal user information displayed

### Performance TODOs
- [ ] Implement message pagination with infinite scroll
- [ ] Add caching layer for user availability status
- [ ] Optimize presence queries for large member lists
- [ ] Implement channel message limits/archiving

### Feature TODOs
- [ ] Rich text message formatting (markdown)
- [ ] File/image upload and preview
- [ ] Direct messages between users
- [ ] User profiles with avatars
- [ ] Server categories for channel organization
- [ ] Advanced role permissions system
- [ ] Message reactions/emoji
- [ ] Message search functionality
- [ ] Notification system

### Security TODOs
- [ ] Rate limiting on message sending
- [ ] Input sanitization for XSS prevention
- [ ] CSRF token validation
- [ ] Audit logging for admin actions

---

## Troubleshooting

### Common Issues

**Issue:** User shows as online when set to invisible
**Solution:** Database is now source of truth. Ensure `online_user_ids/0` filters by `user.availability != :invisible`

**Issue:** Status not updating across tabs
**Solution:** Each tab has separate LiveView process. Status reads from database, so should sync automatically on presence_diff events.

**Issue:** Zombie sessions not cleaning up
**Solution:** Check heartbeat timing. Sessions become zombies after 60s without heartbeat, cleanup after 180s.

**Issue:** Messages not appearing in real-time
**Solution:** Verify PubSub subscription to correct guild topic. Check that `Phoenix.PubSub` is started in application supervisor.

**Issue:** Guild process crashes
**Solution:** Check logs for errors. Guild processes auto-restart via DynamicSupervisor. State is rebuilt from database.

---

## Deployment Considerations

### Production Checklist
- [ ] Set `SECRET_KEY_BASE` environment variable
- [ ] Configure `PHX_HOST` for your domain
- [ ] Set `DATABASE_URL` to production database
- [ ] Configure email provider for auth emails
- [ ] Set up SSL/TLS certificates
- [ ] Enable production logger level
- [ ] Configure session cookie security
- [ ] Set up monitoring and alerting

### Environment Variables (Production)
```bash
SECRET_KEY_BASE=<generated-secret>
DATABASE_URL=postgresql://...
PHX_HOST=yourdomain.com
PORT=4000
POOL_SIZE=10
```

### Scaling Considerations
- **Multiple Nodes:** Phoenix.Presence and PubSub support clustering
- **Database Connection Pool:** Adjust `POOL_SIZE` based on load
- **Session Storage:** Consider Redis for session storage
- **Asset Serving:** Use CDN for static assets
- **Load Balancing:** Sticky sessions recommended for LiveView

---

## Architecture Diagrams

### High-Level System Architecture
```
┌─────────────────────────────────────────────────────────┐
│                    Client Browser                       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│  │   ChatLive   │  │  GatewayLive │  │   AuthPages  │ │
│  └──────────────┘  └──────────────┘  └──────────────┘ │
└────────────┬────────────────┬─────────────────┬────────┘
             │ LiveView       │ WebSocket       │ HTTP
             │                │                 │
┌────────────▼────────────────▼─────────────────▼────────┐
│              Phoenix Endpoint / Router                  │
└────────────┬────────────────┬─────────────────┬────────┘
             │                │                 │
    ┌────────▼────────┐  ┌───▼─────────┐  ┌───▼────────┐
    │   ChatLive      │  │   Session   │  │   Auth     │
    │   (LiveView)    │  │  GenServer  │  │ Controller │
    └────────┬────────┘  └───┬─────────┘  └────────────┘
             │               │
    ┌────────▼───────────────▼────────┐
    │      Phoenix.PubSub             │
    │  ┌──────────┐  ┌──────────┐    │
    │  │guild:123 │  │users:    │    │
    │  │          │  │online    │    │
    │  └──────────┘  └──────────┘    │
    └────────┬────────────────────────┘
             │
    ┌────────▼────────┐
    │  GuildServer    │
    │   GenServer     │
    │ (per server)    │
    └────────┬────────┘
             │
    ┌────────▼────────────────────────┐
    │      Ash Framework              │
    │  ┌──────────┐  ┌──────────┐    │
    │  │Accounts  │  │  Chat    │    │
    │  │ Domain   │  │ Domain   │    │
    │  └──────────┘  └──────────┘    │
    └────────┬────────────────────────┘
             │
    ┌────────▼────────┐
    │   PostgreSQL    │
    │    Database     │
    └─────────────────┘
```

### Message Flow
```
User Types Message
       │
       ▼
ChatLive.handle_event("send_message")
       │
       ▼
Chat.send_message(%{channel_id, author_id, content})
       │
       ▼
Ash creates Message in database
       │
       ▼
GuildServer.send_message(guild_id, message)
       │
       ▼
Phoenix.PubSub.broadcast("guild:#{guild_id}", {:message_create, message})
       │
       ├──────────┬──────────┬──────────┐
       ▼          ▼          ▼          ▼
  ChatLive   ChatLive   ChatLive   Session
  (Tab 1)    (Tab 2)    (Tab 3)   (Gateway)
       │          │          │          │
       ▼          ▼          ▼          ▼
   handle_info({:guild_event, {:message_create, msg}})
       │          │          │          │
       ▼          ▼          ▼          ▼
  Append to   Append to   Append to  Dispatch
  @messages   @messages   @messages   Event
       │          │          │          │
       ▼          ▼          ▼          ▼
  UI Update   UI Update   UI Update  WebSocket
                                      Send
```

### Presence Flow
```
User Connects (ChatLive.mount)
       │
       ▼
Presence.track(self(), "users:online", user_id, metadata)
       │
       ▼
Phoenix.Presence broadcasts presence_diff
       │
       ├────────────┬────────────┐
       ▼            ▼            ▼
  ChatLive     ChatLive     ChatLive
  (All instances)
       │
       ▼
handle_info(%Broadcast{event: "presence_diff"})
       │
       ▼
assign(:online_users, Presence.online_user_ids())
       │
       ▼
Filter invisible users (read from database)
       │
       ▼
UI updates member status indicators
```

---

## Code Conventions

### Naming Conventions
- **Modules:** PascalCase (e.g., `Banter.Chat.Server`)
- **Functions:** snake_case (e.g., `send_message/2`)
- **Variables:** snake_case (e.g., `user_id`)
- **Atoms:** snake_case (e.g., `:online`, `:away`)
- **Module Attributes:** snake_case with @ (e.g., `@heartbeat_interval`)

### File Organization
- One resource per file
- Group related modules in directories
- Keep LiveView files in `lib/banter_web/live/`
- Keep domain logic in `lib/banter/`

### Documentation
- Use `@moduledoc` for module-level documentation
- Use `@doc` for public function documentation
- Include examples in docstrings where helpful
- Document complex algorithms with inline comments

### Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples
- Pattern match on success/error cases
- Log errors with appropriate log levels
- Return meaningful error messages to users

---

## Resources & References

### Official Documentation
- [Phoenix Framework](https://hexdocs.pm/phoenix/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ash Framework](https://hexdocs.pm/ash/)
- [AshAuthentication](https://hexdocs.pm/ash_authentication/)
- [Phoenix.Presence](https://hexdocs.pm/phoenix/Phoenix.Presence.html)

### Key Dependencies
```elixir
# Core
{:phoenix, "~> 1.7"}
{:phoenix_live_view, "~> 0.20"}
{:ash, "~> 3.0"}
{:ash_postgres, "~> 2.0"}
{:ash_authentication, "~> 4.0"}

# Database & Jobs
{:ecto_sql, "~> 3.10"}
{:postgrex, ">= 0.0.0"}
{:oban, "~> 2.17"}

# Authentication
{:bcrypt_elixir, "~> 3.0"}
{:jason, "~> 1.2"}

# Assets
{:tailwind, "~> 0.2"}
{:esbuild, "~> 0.8"}
```

### Discord API Reference
This project implements a subset of the Discord Gateway protocol:
- [Discord Gateway Documentation](https://discord.com/developers/docs/topics/gateway)
- [Discord Gateway Events](https://discord.com/developers/docs/topics/gateway-events)

---

## Changelog

### February 6, 2026
- **Added:** User availability status system (online/away/dnd/invisible)
- **Added:** Status dropdown UI in ChatLive
- **Fixed:** Invisible users now properly hidden from online list
- **Fixed:** Status reads from database (source of truth) instead of Presence metadata
- **Improved:** Multi-connection handling for user status
- **Updated:** Authorization policy for update_availability action

### Earlier Features
- Initial project setup with Phoenix and Ash
- User authentication with email/password
- Server (guild) creation and management
- Channel creation and organization
- Real-time messaging with PubSub
- WebSocket Gateway protocol implementation
- Session management with heartbeat
- Member list with role management
- Invite code system for joining servers
- Phoenix.Presence integration for online status

---

## Contributing Guidelines

### Code Style
- Follow Elixir standard formatting (use `mix format`)
- Add typespecs to public functions
- Write descriptive commit messages
- Keep functions focused and concise
- Use pattern matching over conditionals where possible

### Pull Request Process
1. Create feature branch from main
2. Write tests for new functionality
3. Ensure all tests pass (`mix test`)
4. Format code (`mix format`)
5. Update documentation as needed
6. Submit PR with clear description

### Testing Requirements
- Unit tests for business logic
- Integration tests for API endpoints
- LiveView tests for user interactions
- Maintain > 80% code coverage

---

## License & Credits

**License:** MIT (or your chosen license)

**Created by:** Ali Akram
**Date:** February 6, 2026
**Framework:** Phoenix + Ash
**Inspired by:** Discord

---

**End of Documentation**

*Last Updated: February 6, 2026*

---

## File Upload System

### Overview
Messages support image file uploads with the following features:
- **File Types:** Images only (.jpg, .jpeg, .png, .gif, .webp, .svg)
- **Max File Size:** 25 MB per image
- **Max Attachments:** 10 images per message
- **Storage:** Local filesystem at `priv/static/uploads/`
- **Real-time:** Attachments broadcast with messages via PubSub

### Architecture Components

1. **Storage Module** (`lib/banter/storage.ex`)
   - Handles file system operations
   - Generates UUID filenames
   - Creates hierarchical directory structure
   - Returns storage path and public URL

2. **Attachment Resource** (`lib/banter/chat/attachment.ex`)
   - Ash resource for file metadata
   - Validates image content types
   - Enforces 25 MB size limit
   - Belongs to Message (CASCADE delete)

3. **Message Updates** (`lib/banter/chat/message.ex`)
   - Content now optional (can send attachments without text)
   - `has_many :attachments` relationship
   - Accepts attachments as array of maps in create action
   - Validation: must have content OR attachments

4. **LiveView Integration** (`lib/banter_web/live/chat/chat_live.ex`)
   - `allow_upload` configuration for file selection
   - `consume_uploaded_entries` processes uploaded files
   - Calls Storage.upload_file for each image
   - Passes attachment data to GuildServer

5. **UI Components** (`lib/banter_web/live/chat/components.ex`)
   - File upload button with hidden file input
   - Upload preview area with thumbnails
   - Progress indicators
   - Message display with attachment grid
   - Clickable images that open in new tab

### File Storage Structure

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

### Static File Serving

Configured in `lib/banter_web/endpoint.ex`:

1. **Primary Static Plug** - Serves general static files with `:only` whitelist
2. **Uploads Static Plug** - Serves uploaded files from `/uploads/` path

**CRITICAL:** Must add "uploads" to `static_paths()` in `lib/banter_web.ex`

### Database Schema

```sql
CREATE TABLE attachments (
  id UUID PRIMARY KEY,
  filename VARCHAR(255) NOT NULL,
  size INTEGER NOT NULL CHECK (size BETWEEN 1 AND 25000000),
  content_type VARCHAR(100) NOT NULL CHECK (content_type LIKE 'image/%'),
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

### Upload Flow

1. User selects images → LiveView tracks uploads
2. User clicks send → `handle_event("send_message")`
3. `consume_uploaded_entries` processes each image:
   - Calls `Storage.upload_file(temp_path, server_id, channel_id, filename, type)`
   - Returns `{:ok, %{storage_path:, url:}}`
4. Creates message with attachments via `manage_relationship`
5. Loads attachments: `Ash.load!(message, :attachments)`
6. Broadcasts via PubSub to guild topic
7. All connected clients receive message with images
8. UI renders message with attachment grid

### Future Migration

Code is structured for easy migration to MinIO/S3:
- Only `Storage` module needs backend abstraction
- Attachment records, Message resource, LiveView, UI remain unchanged
- Can run migration script to move existing files

### Related Documentation

See [FILE_UPLOAD_GUIDE.md](FILE_UPLOAD_GUIDE.md) for comprehensive implementation details.

---

**Last Updated:** 2026-02-08
