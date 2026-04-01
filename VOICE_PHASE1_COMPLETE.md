# Voice/Video Phase 1 — Data Model & Dependencies (Complete)

**Date:** 2026-02-10
**Status:** Complete

---

## What Was Done

### 1. Membrane Framework Dependencies Added

**File:** `mix.exs`

```elixir
{:membrane_rtc_engine, "~> 0.23.0"},
{:membrane_rtc_engine_webrtc, "~> 0.9.0"},
{:bundlex, "~> 1.5", override: true}
```

- `membrane_rtc_engine` — SFU core engine (manages rooms with multiple participants)
- `membrane_rtc_engine_webrtc` — WebRTC endpoint for the RTC engine
- `bundlex` override — resolves `req ~> 0.5` compatibility with Membrane's transitive deps

**Version note:** `membrane_rtc_engine` 0.25.0 and `membrane_rtc_engine_webrtc` 0.9.0 are incompatible (conflicting `membrane_rtp_plugin` versions). The compatible pair is `rtc_engine ~> 0.23.0` + `rtc_engine_webrtc ~> 0.9.0`.

**OpenSSL requirement:** Membrane's `fast_tls` dep needs OpenSSL headers on macOS:
```bash
C_INCLUDE_PATH=/opt/homebrew/opt/openssl@3/include \
LIBRARY_PATH=/opt/homebrew/opt/openssl@3/lib \
mix deps.compile fast_tls --force
```

### 2. VoiceState Ash Resource Created

**File:** `lib/banter/chat/voice_state.ex`

Tracks active voice channel connections. Transient records — created on join, hard-deleted on leave.

| Attribute | Type | Notes |
|-----------|------|-------|
| `id` | UUID v7 | Time-ordered primary key |
| `user_id` | UUID | FK to users (cascade delete) |
| `channel_id` | UUID | FK to channels (cascade delete) |
| `server_id` | UUID | FK to servers (cascade delete, denormalized) |
| `self_mute` | boolean | Default false |
| `self_deaf` | boolean | Default false |

**Key constraint:** `unique_user_voice` identity on `[:user_id]` — a user can only be in ONE voice channel globally.

**Actions:**
- `:join` (create) — accepts user_id, channel_id, server_id
- `:update` — toggle self_mute/self_deaf
- `:destroy` — leave voice channel
- `:by_channel` — list all users in a voice channel
- `:by_server` — list all voice states in a server
- `:by_user` — get a user's current voice state (get? true)

**No soft-delete** — voice states are ephemeral, AshArchival not used.

### 3. Chat Domain Updated

**File:** `lib/banter/chat.ex`

Registered VoiceState with domain-level code interface:

```elixir
Chat.join_voice_channel(%{user_id: ..., channel_id: ..., server_id: ...})
Chat.leave_voice_channel(voice_state)
Chat.list_voice_states_by_channel(%{channel_id: id})
Chat.list_voice_states_by_server(%{server_id: id})
Chat.get_user_voice_state(user_id)
Chat.update_voice_state(voice_state, %{self_mute: true})
```

Convenience functions added:
- `Chat.list_voice_states_for_channel(channel_id)` — unwraps ok tuple
- `Chat.list_voice_states_for_server(server_id)` — unwraps ok tuple

### 4. Supervisor Tree Extended

**File:** `lib/banter/application.ex`

Added (before Endpoint):
```elixir
{Registry, keys: :unique, name: Banter.VoiceRoomRegistry}
{DynamicSupervisor, strategy: :one_for_one, name: Banter.VoiceRoomSupervisor}
```

These are ready for Phase 3's `Voice.Room` GenServer (Membrane RTC Engine wrapper).

### 5. ICE Server Config

**File:** `config/dev.exs`

```elixir
config :banter, :webrtc,
  ice_servers: [%{urls: "stun:stun.l.google.com:19302"}]
```

### 6. Migration

**File:** `priv/repo/migrations/20260210135830_add_voice_states.exs`

Creates `voice_states` table with:
- UUID v7 primary key (`uuid_generate_v7()`)
- 3 foreign keys with `on_delete: :delete_all`
- Unique index on `user_id` (one voice channel per user)

---

## What Already Existed (No Changes Needed)

- **Channel type:** `channel.ex` already supports `:voice` type (`constraints one_of: [:text, :voice, :announcement]`)
- **`.gitignore`:** Already has `/assets/node_modules/`

---

## Files Changed

| File | Action |
|------|--------|
| `mix.exs` | Modified — 3 new deps |
| `lib/banter/chat/voice_state.ex` | Created — Ash resource |
| `lib/banter/chat.ex` | Modified — registered VoiceState |
| `lib/banter/application.ex` | Modified — VoiceRoom supervisor infra |
| `config/dev.exs` | Modified — ICE config |
| `priv/repo/migrations/20260210135830_add_voice_states.exs` | Auto-generated |
| `priv/resource_snapshots/repo/voice_states/20260210135830.json` | Auto-generated |

---

## Next: Phase 2 — Voice Channel UI

See [VOICE_VIDEO_GUIDE.md](VOICE_VIDEO_GUIDE.md) for the full implementation plan.
