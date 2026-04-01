# Claude.md - AI Assistant Guide

**Project:** Discord Clone
**Framework:** Phoenix LiveView + Ash Framework 3.0
**Language:** Elixir
**Purpose:** Real-time chat application with WebSocket gateway

---

## Quick Reference

### Project Overview
A Discord-inspired chat application featuring:
- Real-time messaging with Phoenix PubSub
- User presence tracking with custom statuses (online/away/dnd/invisible)
- WebSocket gateway protocol for external clients
- Guild (server) system with channels and role-based permissions
- Voice channels with WebRTC audio (Membrane Framework SFU)
- File uploads with local storage
- Authentication with AshAuthentication + Bcrypt

### Technology Stack
- **Backend:** Phoenix 1.8 + LiveView
- **Data Layer:** Ash Framework 3.0 + PostgreSQL
- **Real-time:** Phoenix PubSub + Phoenix.Presence
- **Auth:** AshAuthentication with JWT tokens
- **Background Jobs:** Oban
- **Voice/Video:** Membrane Framework + membrane_webrtc_plugin (pure Elixir WebRTC SFU)
- **IDs:** UUID v7 (time-ordered)

---

## File Structure Guide

### Core Application
```
lib/banter/
├── application.ex              # OTP supervisor - starts GenServers, PubSub, Registry
├── repo.ex                     # Ecto repository
├── accounts.ex                 # Accounts domain (users, auth)
├── chat.ex                     # Chat domain (servers, channels, messages, voice states)
├── gateway.ex                  # Gateway protocol helpers
├── guild_server.ex             # GenServer per guild - manages state
├── session.ex                  # GenServer per WebSocket - heartbeat monitoring
├── storage.ex                  # File upload storage helpers
├── presence.ex                 # Presence wrapper (in web/)
├── secrets.ex                  # JWT signing secrets
├── snowflake.ex                # Unused - project uses UUID v7
├── voice/
│   ├── room.ex                 # GenServer per voice channel - manages pipeline lifecycle
│   └── pipeline.ex             # Membrane Pipeline for SFU audio routing
└── workers/
    └── voice_cleanup_worker.ex # Oban cron worker - sweeps stale voice states
```

### Resources (Ash)
```
lib/banter/
├── accounts/
│   ├── user.ex                 # User resource with authentication
│   └── token.ex                # Auth tokens
└── chat/
    ├── server.ex               # Guild/server resource
    ├── channel.ex              # Channel resource (text + voice types)
    ├── message.ex              # Message resource
    ├── attachment.ex           # File attachment resource
    ├── membership.ex           # Server membership with roles
    └── voice_state.ex          # Voice channel state (transient, hard-delete on leave)
```

### Web Layer
```
lib/banter_web/
├── endpoint.ex                 # Phoenix endpoint config
├── router.ex                   # Routes - live sessions, auth
├── presence.ex                 # Phoenix.Presence module
├── live_user_auth.ex           # LiveView auth helpers
├── controllers/
│   └── auth_controller.ex      # Auth callbacks
└── live/
    ├── chat_live.ex            # Main chat UI (LiveView)
    └── gateway_live.ex         # WebSocket gateway endpoint
```

---

## Architecture Patterns

### 1. Domain-Driven Design
Two main domains: **Accounts** and **Chat**
- Each domain has resources (Ash.Resource)
- Resources define actions, attributes, relationships, policies
- Use `Ash.Changeset.for_action()` and `Ash.create/update/read/destroy()`

### 2. GenServer Processes
- **GuildServer:** One process per active server (manages channels, members, broadcasts)
- **Session:** One process per gateway connection (heartbeat monitoring)
- **Voice.Room:** One process per active voice channel (manages Membrane pipeline for audio routing)
- Registered via `Registry` for fast lookup (`GuildRegistry`, `VoiceRoomRegistry`)
- Auto-cleanup when unused (GuildServer: 30 min, Voice.Room: 5 min)

### 3. PubSub Topics
```elixir
"guild:#{guild_id}"    # Server-specific events (messages, channels, members)
"users:online"         # Global presence updates
# Voice events use the guild topic — no separate voice topic needed
```

### 4. Presence System
**IMPORTANT:** User status is stored in database (`users.availability`), NOT Presence metadata
- Database = source of truth for status
- Presence = connection tracking only
- Supports multi-connection scenarios (multiple tabs/devices)
- Invisible users filtered from online list

---

## Common Tasks

### Reading Data
```elixir
# Simple read
{:ok, user} = Ash.get(User, user_id)

# With relationships loaded
{:ok, server} = Ash.get(Server, server_id, load: [:channels, :members])

# List with query
{:ok, servers} = Ash.read(Server)
```

### Creating Records
```elixir
# Using Ash actions
Server
|> Ash.Changeset.for_create(:create, %{name: "My Server", owner_id: user_id})
|> Ash.create()
```

### Updating Records
```elixir
# User status update
user
|> Ash.Changeset.for_update(:update_availability, %{availability: :away})
|> Ash.update()
```

### GenServer Interactions
```elixir
# Start guild server
{:ok, pid} = GuildServer.start_link(guild_id: guild_id)

# Call guild server
GuildServer.create_channel(guild_id, %{name: "general"})
GuildServer.send_message(guild_id, message)
```

### PubSub Broadcasting
```elixir
# Broadcast to guild topic
Phoenix.PubSub.broadcast(
  Banter.PubSub,
  "guild:#{guild_id}",
  {:guild_event, {:message_create, message}}
)

# Subscribe to topic
Phoenix.PubSub.subscribe(Banter.PubSub, "guild:#{guild_id}")
```

### Presence Tracking
```elixir
# Track user presence
Presence.track(self(), "users:online", user_id, %{
  online_at: System.system_time(:second),
  status: user.availability,
  email: user.email
})

# Get online users (filters invisible)
online_users = Presence.online_user_ids()
```

---

## Key Conventions

### Database
- **Primary Keys:** UUID (`:uuid` type in Ash)
- **Timestamps:** Time-ordered UUID v7 for servers, channels, messages
- **Foreign Keys:** `user_id`, `server_id`, `channel_id`, `author_id`
- **Enums:** `:online`, `:away`, `:dnd`, `:invisible` for availability
- **Roles:** `:owner`, `:admin`, `:member` for memberships

### Naming
- **Servers = Guilds** (Discord terminology, but we use "Server" in UI)
- **Availability = Status** (stored in `users.availability`)
- **Channels** belong to Servers
- **Messages** belong to Channels
- **Memberships** join Users to Servers

### Authorization
- Owner-based policies use `relates_to_actor_via(:owner_id)`
- Custom policies check membership: `actor_is_member()`
- All auth actions bypass with `AshAuthentication.Checks.AshAuthenticationInteraction`

### LiveView Assigns
Common assigns in ChatLive:
```elixir
@current_user       # Authenticated user struct
@servers            # User's servers
@current_server     # Selected server
@channels           # Channels in current server
@current_channel    # Selected channel
@messages           # Messages in current channel
@members            # Server members
@online_users       # List of online user IDs (excludes invisible)
@messages_cursor    # UUID v7 ID of oldest loaded message (for pagination)
@has_more_messages  # Whether older messages exist
@loading_more_messages # Loading state for scroll-up pagination
@voice_states       # %{channel_id => [%VoiceState{}, ...]}
@current_voice_channel # channel struct or nil
@voice_muted        # boolean
@voice_deafened     # boolean
```

---

## Important Gotchas

### 1. User Status System
**DO NOT** store status in Presence metadata as source of truth!
- ✅ Read from database: `user.availability`
- ✅ Update database first, then Presence
- ❌ Don't read status from Presence metadata
- **Why:** Users can have multiple connections (tabs/devices)

### 2. Online Users List
Must filter invisible users:
```elixir
def online_user_ids do
  "users:online"
  |> Presence.list()
  |> Enum.filter(fn {user_id, _} ->
    case Ash.get(User, user_id) do
      {:ok, user} -> user.availability != :invisible
      _ -> true
    end
  end)
  |> Enum.map(fn {user_id, _} -> user_id end)
end
```

### 3. GenServer Registry
Processes registered dynamically:
```elixir
# Guild servers
{:via, Registry, {Banter.Registry, {:guild, guild_id}}}

# Sessions
{:via, Registry, {Banter.Registry, {:session, session_id}}}
```

### 4. Ash Actions
Must use defined actions, not raw Ecto:
```elixir
# ✅ Correct
Server |> Ash.Changeset.for_create(:create, attrs) |> Ash.create()

# ❌ Wrong
%Server{} |> Ecto.Changeset.change(attrs) |> Repo.insert()
```

### 5. Message Pagination — Use UUID v7 ID as Cursor
**DO NOT** use `inserted_at` timestamps for cursor-based pagination!
- ✅ Use the UUID v7 `id` field: `id < ^arg(:before_id)`
- ❌ Don't use `inserted_at < ^arg(:before)` — Ash/Ecto truncates microseconds to seconds
- **Why:** `utc_datetime_usec` values lose microsecond precision when cast to `timestamptz` in SQL parameters, causing the same page of results to be returned repeatedly
- Single `by_channel` action handles both initial load (no `before_id`) and pagination (with `before_id`)
- Fetches 51 rows, displays 50 — the extra row indicates `has_more_messages`

### 6. Ash Code Interface — Positional vs Map Args
```elixir
# With args: positional call
define :my_func, args: [:foo], action: :bar
# Call: my_func(foo_value) ✅
# Call: my_func(%{foo: foo_value}) ❌ — silently fails!

# Without args: map call
define :my_func, action: :bar
# Call: my_func(%{foo: foo_value}) ✅
```
Mixing these up causes silent failures — the map becomes the arg value, type mismatch is swallowed.

### 7. LiveView Authentication
Protected routes use `live_session`:
```elixir
live_session :authenticated, on_mount: BanterWeb.LiveUserAuth do
  live "/chat", ChatLive
end
```

---

## Testing

### Run Tests
```bash
mix test                    # All tests
mix test test/path_test.exs # Specific file
mix test --cover            # With coverage
```

### Test Database
Separate database: `banter_test`
Auto-reset between tests via sandbox mode

### Load Testing
See [LOAD_TEST_GUIDE.md](LOAD_TEST_GUIDE.md) for WebSocket load testing

---

## Development Workflow

### Setup
```bash
mix setup                   # Install deps, setup DB, build assets
mix phx.server              # Start server (localhost:4000)
iex -S mix phx.server       # Start with IEx console
```

### Database
```bash
mix ash.reset               # Drop, create, migrate
mix ecto.migrate            # Run migrations
mix ecto.rollback           # Rollback last
```

### Code Quality
```bash
mix format                  # Format code
mix compile --warnings-as-errors
```

---

## Message Flow Example

User sends message:
```
1. User types in ChatLive message input
2. ChatLive.handle_event("send_message", %{"content" => text})
3. Chat.send_message(%{channel_id:, author_id:, content:})
4. Ash creates Message in database (UUID v7 ID)
5. GuildServer.send_message(guild_id, message)
6. PubSub.broadcast("guild:#{guild_id}", {:message_create, message})
7. All subscribed ChatLive processes receive {:guild_event, {:message_create, msg}}
8. ChatLive.handle_info appends message to @messages
9. UI updates via LiveView diff
```

---

## Gateway Protocol

### Opcodes
```elixir
0  - Dispatch (server events)
1  - Heartbeat (client -> server)
2  - Identify (client auth)
6  - Resume (reconnect)
10 - Hello (initial handshake)
11 - Heartbeat ACK
```

### Session States
- `:waiting_identify` - Awaiting IDENTIFY
- `:identified` - Active session
- `:zombie` - Missed heartbeat

### Heartbeat Timing
```elixir
@heartbeat_interval 45_000   # 45s - client must send heartbeat
@heartbeat_timeout 60_000    # 60s - grace period before zombie
@zombie_timeout 180_000      # 3min - cleanup zombie sessions
```

---

## Documentation

### Detailed Guides
- [PROJECT_DOCUMENTATION_2026-02-06.md](PROJECT_DOCUMENTATION_2026-02-06.md) - Comprehensive project docs
- [ONLINE_STATUS_GUIDE.md](ONLINE_STATUS_GUIDE.md) - User presence system
- [HEARTBEAT_MONITORING.md](HEARTBEAT_MONITORING.md) - Gateway heartbeat details
- [LOAD_TEST_GUIDE.md](LOAD_TEST_GUIDE.md) - WebSocket load testing
- [SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md) - Performance considerations
- [SETUP_UI.md](SETUP_UI.md) - UI setup guide
- [FILE_UPLOAD_GUIDE.md](FILE_UPLOAD_GUIDE.md) - File upload system implementation
- [VOICE_VIDEO_GUIDE.md](VOICE_VIDEO_GUIDE.md) - WebRTC voice/video implementation plan

### External Resources
- [Phoenix Docs](https://hexdocs.pm/phoenix/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ash Framework](https://hexdocs.pm/ash/)
- [AshAuthentication](https://hexdocs.pm/ash_authentication/)
- [Phoenix.Presence](https://hexdocs.pm/phoenix/Phoenix.Presence.html)
- [Membrane Framework](https://membrane.stream/) - Elixir multimedia framework (SFU for voice/video)
- [membrane_webrtc_plugin (Hex)](https://hex.pm/packages/membrane_webrtc_plugin) - WebRTC plugin with LiveView integration
- [membrane_webrtc_plugin (Docs)](https://hexdocs.pm/membrane_webrtc_plugin/) - API docs (Source, Sink, Signaling, Live.Capture/Player)
- [ex_webrtc](https://github.com/elixir-webrtc/ex_webrtc) - Pure Elixir WebRTC implementation (used by membrane_webrtc_plugin)
- [MDN WebRTC API](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API) - Browser WebRTC reference

---

## Working with Claude

### When Adding Features
1. Read relevant files first (use Read tool)
2. Understand existing patterns in codebase
3. Follow Ash conventions for resources
4. Use GenServers for stateful processes
5. Broadcast events via PubSub for real-time updates
6. Test locally with `mix phx.server`

### When Debugging
1. Check application.ex for supervisor tree
2. Verify PubSub subscriptions
3. Check Presence tracking for online issues
4. Review GenServer state with `:sys.get_state(pid)`
5. Use `dbg()` or `IO.inspect()` for debugging
6. Check logs with `Logger.debug/info/error`

### When Modifying Resources
1. Edit resource file (e.g., `lib/banter/chat/server.ex`)
2. Add/modify actions, attributes, relationships
3. Run `mix ash.codegen` if using Ash codegen features
4. Create migration if schema changed: `mix ash_postgres.generate_migrations`
5. Run migration: `mix ecto.migrate`

### Best Practices
- Always read files before modifying
- Follow existing code patterns
- Don't over-engineer - keep it simple
- Test changes locally before committing
- Update documentation when adding features
- Use Ash actions, not raw Ecto queries

---

## Quick Command Reference

```bash
# Development
mix phx.server                  # Start server
iex -S mix phx.server           # Start with console

# Database
mix ash.reset                   # Reset DB
mix ash_postgres.generate_migrations  # Generate migrations
mix ash_postgress.migrate                # Run migrations

# Code Quality
mix format                      # Format code
mix test                        # Run tests

# Dependencies
mix deps.get                    # Install deps
mix deps.clean --unused         # Clean unused deps

# Assets
cd assets && npm install        # Install JS deps
mix assets.build                # Build assets
```

---

## Status Colors Reference

```elixir
:online    -> "bg-[#3ba55c]"  # Green
:away      -> "bg-[#faa61a]"  # Yellow/Orange
:dnd       -> "bg-[#f04747]"  # Red (Do Not Disturb)
:invisible -> "bg-[#747f8d]"  # Gray (appears offline)
:offline   -> "bg-[#747f8d]"  # Gray
```

---

## Environment Variables

### Development (.env)
```bash
DATABASE_URL=postgresql://postgres:postgres@localhost/banter_dev
SECRET_KEY_BASE=<generate with mix phx.gen.secret>
PHX_HOST=localhost
PORT=4000
```

### Required for Production
- `SECRET_KEY_BASE` - Phoenix secret
- `DATABASE_URL` - PostgreSQL connection
- `PHX_HOST` - Domain name
- `PORT` - Server port

### Voice/Video (when implemented)
```elixir
# No external service URLs needed — Membrane runs in-process
# config/dev.exs
config :banter, :webrtc,
  ice_servers: [%{urls: "stun:stun.l.google.com:19302"}]
```

---

## Common Issues & Solutions

### Issue: User appears online when invisible
**Solution:** Check `Presence.online_user_ids/0` filters by `availability != :invisible`

### Issue: Status not syncing across tabs
**Solution:** Database is source of truth. Check presence_diff handling.

### Issue: Messages not appearing
**Solution:** Verify PubSub subscription to `"guild:#{guild_id}"` topic

### Issue: GenServer crashes
**Solution:** Check logs. Process auto-restarts via DynamicSupervisor.

### Issue: Authentication fails
**Solution:** Verify token signing secret in `Banter.Secrets`

---

## Project Goals

**Current State:** Core chat + voice channel infrastructure working
**Next Up:** Voice/video Phase 3 Steps 3-4 — client-side WebRTC integration (see [VOICE_VIDEO_GUIDE.md](VOICE_VIDEO_GUIDE.md))
**Completed:**
- ✅ Message pagination with UUID v7 cursor
- ✅ Image file uploads with local storage
- ✅ Voice channel UI with join/leave/mute/deafen (Phase 2)
- ✅ Page-refresh voice state fix + Oban cleanup worker (Phase 2.5)
- ✅ Membrane dep swap + Voice.Room GenServer + Pipeline (Phase 3 Steps 1-2)
**In Progress:**
- Voice/video channels — real audio (Phase 3 Steps 3-4: LiveView signaling + JS hooks)
**Future:**
- Direct messages
- Rich text formatting

---

**Last Updated:** 2026-02-11
**For Questions:** Check PROJECT_DOCUMENTATION_2026-02-06.md or explore the codebase!
