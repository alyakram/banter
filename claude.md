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
- Voice channels with WebRTC audio (ex_webrtc, pure Elixir — audio only, video not yet implemented)
- File uploads with local storage
- Authentication with AshAuthentication + Bcrypt

### Technology Stack
- **Backend:** Phoenix 1.8 + LiveView
- **Data Layer:** Ash Framework 3.0 + PostgreSQL
- **Real-time:** Phoenix PubSub + Phoenix.Presence
- **Auth:** AshAuthentication with JWT tokens
- **Background Jobs:** Oban
- **Voice:** ex_webrtc (pure Elixir WebRTC) — custom SFU via `Voice.Room`/`Voice.Peer` GenServers, no Membrane, no external SFU server. Audio only; video is not implemented.
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
│   ├── room.ex                 # GenServer per voice channel - SFU fan-out hub (VoiceRoomRegistry)
│   └── peer.ex                 # GenServer per participant - wraps one ExWebRTC.PeerConnection
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
- **Voice.Room:** One process per active voice channel — SFU fan-out hub, fans RTP packets between participants
- **Voice.Peer:** One process per participant in a voice channel — wraps one `ExWebRTC.PeerConnection`
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
`Server`, `Channel`, `Member`, `VoiceState`, and `Message` all have
`authorizers: [Ash.Policy.Authorizer]` with real policies (not just declared —
actually enforced). Patterns used:
- Reads are membership-gated: `authorize_if expr(exists(server.members, user_id == ^actor(:id)))`
  (or `exists(members, ...)` directly on `Server`)
- Self-only update/destroy: `authorize_if expr(user_id == ^actor(:id))` (or `author_id`/`owner_id`)
- All auth actions bypass with `bypass AshAuthentication.Checks.AshAuthenticationInteraction`
- **Create actions can't use `expr()` relationship or attribute filters** — Ash has no persisted
  row yet to filter against and raises `Cannot use a filter to authorize a create`. Two custom
  `Ash.Policy.SimpleCheck` modules in `lib/banter/chat/checks/` handle this: `ActorIsServerMember`
  resolves `server_id` off the changeset/query directly and does a real membership lookup;
  `ActorSelfJoinsAsMember` reads the post-default attribute value (not `^arg(:role)`, which is
  `nil` when the client omits the field even though the attribute still gets its default)
- Because these policies are real, **every call site touching these resources must pass the right
  `actor:`** (or an explicitly-commented `authorize?: false` for genuinely trusted internal-process
  paths — GuildServer's own state bootstrap, its already-membership-validated `create_channel`,
  the Oban voice cleanup sweep). Forgetting this doesn't error at compile time — it silently denies
  or returns `NotFound`, so watch for that when adding new features here.
- `Message`'s `read`/`create` policies are still `authorize_if always()` — a known gap, tracked in
  `AUDIT_FINDINGS.md`, deliberately left alone so the Server/Channel/Member/VoiceState PR stayed
  reviewable

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

### 8. Ash Policies — Create Actions Can't Filter on Relationships/Attributes
```elixir
# ❌ Wrong — raises "Cannot use a filter to authorize a create"
policy action_type(:create) do
  authorize_if expr(owner_id == ^actor(:id))
end

# ✅ Right — reference the changeset argument instead (a static value, not a filter)
policy action_type(:create) do
  authorize_if expr(^actor(:id) == ^arg(:owner_id))
end

# ✅ For relationship checks on create (e.g. "actor is a member of the
# server this row is being created for"), write a custom
# Ash.Policy.SimpleCheck that resolves the id off the changeset and runs a
# real query — see lib/banter/chat/checks/actor_is_server_member.ex
```
**Why:** on create there's no persisted row yet, so Ash can't build a SQL filter to check against
it — that machinery only works for read/update/destroy. `^arg(:foo)` sidesteps this because it's
a value already on the changeset, not something requiring a query. Also watch out: `^arg(:foo)` is
only reliable for **required** arguments — if an attribute has a default and the client omits it,
`arg/1` sees `nil` while the attribute already has its default applied. Use
`Ash.Changeset.get_attribute/2` inside a custom check when that distinction matters (see
`ActorSelfJoinsAsMember`).

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
See [LOAD_TEST_GUIDE.md](docs/LOAD_TEST_GUIDE.md) for WebSocket load testing

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
- [AUDIT_FINDINGS.md](AUDIT_FINDINGS.md) - Codebase security/quality audit tracker — check items off as they're fixed, see it for what's still open
- [PROJECT_DOCUMENTATION_2026-02-06.md](docs/PROJECT_DOCUMENTATION_2026-02-06.md) - Comprehensive project docs
- [ONLINE_STATUS_GUIDE.md](docs/ONLINE_STATUS_GUIDE.md) - User presence system
- [HEARTBEAT_MONITORING.md](docs/HEARTBEAT_MONITORING.md) - Gateway heartbeat details
- [LOAD_TEST_GUIDE.md](docs/LOAD_TEST_GUIDE.md) - WebSocket load testing
- [SCALABILITY_ANALYSIS.md](docs/SCALABILITY_ANALYSIS.md) - Performance considerations
- [SETUP_UI.md](docs/SETUP_UI.md) - UI setup guide
- [FILE_UPLOAD_GUIDE.md](docs/FILE_UPLOAD_GUIDE.md) - File upload system implementation
- [VOICE_VIDEO_GUIDE.md](docs/VOICE_VIDEO_GUIDE.md) - WebRTC voice/video implementation plan

### External Resources
- [Phoenix Docs](https://hexdocs.pm/phoenix/)
- [Phoenix LiveView](https://hexdocs.pm/phoenix_live_view/)
- [Ash Framework](https://hexdocs.pm/ash/)
- [AshAuthentication](https://hexdocs.pm/ash_authentication/)
- [Phoenix.Presence](https://hexdocs.pm/phoenix/Phoenix.Presence.html)
- [ex_webrtc](https://github.com/elixir-webrtc/ex_webrtc) - Pure Elixir WebRTC implementation used directly for the voice SFU (no Membrane)
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

### Voice (implemented — audio only, no external service needed)
`ex_webrtc` runs in-process — no separate SFU server to deploy or configure.
```elixir
# config/dev.exs
config :banter, :webrtc,
  ice_servers: [%{urls: "stun:stun.l.google.com:19302"}]
```
STUN-only works on the same LAN. For cross-network use (different ISPs/mobile data), set
`metered_username`/`metered_password` in `.env` — `dev.exs` reads them and adds a TURN server to
`ice_servers`; `root.html.heex` injects `window.__TURN__` for the browser-side `RTCPeerConnection`
in `hooks.js`. Start the server with `export $(cat .env | xargs) && mix phx.server` when testing
across networks.

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

**Current State:** Core chat + voice channels (audio) working end-to-end
**Next Up:** Voice polish & error handling (see [VOICE_VIDEO_GUIDE.md](docs/VOICE_VIDEO_GUIDE.md)'s
Phase 4/5) — speaking indicators, mic-permission-denied handling, ICE-failure UI feedback, mobile
browser testing
**Completed:**
- ✅ Message pagination with UUID v7 cursor
- ✅ Image file uploads with local storage
- ✅ Voice channels (audio) — join/leave/mute/deafen, real WebRTC audio via `ex_webrtc`
  (`Voice.Room`/`Voice.Peer` SFU), TURN support for cross-network calls
- ✅ Page-refresh voice state fix + Oban cleanup worker
- ✅ Gateway IDENTIFY/RESUME now require a verified AshAuthentication JWT instead of a trusted
  client-supplied `user_id` — closed a full user-impersonation hole
- ✅ Ash authorization policies on `Server`, `Channel`, `Member`, `VoiceState` — previously any
  authenticated user could read/write any guild's data; see the Authorization section above
- ✅ ChatLive redirects non-members away from server/channel URLs they don't have access to
**Future:**
- Video calling — not started; voice (audio-only) is the current ceiling
- Direct messages
- Rich text formatting
- Remaining items in [AUDIT_FINDINGS.md](AUDIT_FINDINGS.md): rate limiting on the gateway, DB
  indexes on FK columns, `Message`'s still-open `read`/`create` policies, SVG upload XSS risk

---

**Last Updated:** 2026-08-23
**For Questions:** Check PROJECT_DOCUMENTATION_2026-02-06.md or explore the codebase!
