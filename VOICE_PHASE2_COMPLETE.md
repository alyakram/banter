# Voice/Video Phase 2 — Voice Channel UI (Complete)

**Date:** 2026-02-10
**Status:** Complete

---

## What Was Done

### 1. Voice Assigns Added to ChatLive

**File:** `lib/banter_web/live/chat/chat_live.ex`

Four new assigns in `mount/3`:

```elixir
|> assign(:voice_states, %{})          # %{channel_id => [%VoiceState{}, ...]}
|> assign(:current_voice_channel, nil) # channel struct if user is in a voice channel
|> assign(:voice_muted, false)
|> assign(:voice_deafened, false)
```

### 2. Voice States Loaded with Server

**File:** `lib/banter_web/live/chat/chat_live.ex` (`load_server/2`)

When a server is loaded, voice states are fetched, grouped by `channel_id`, and assigned. If the current user has an active voice state in this server, `current_voice_channel`, `voice_muted`, and `voice_deafened` are restored from the database.

### 3. Channel List Split into Text + Voice Sections

**File:** `lib/banter_web/live/chat/components.ex` (`channel_list`)

Channels are now filtered by type:
- **Text Channels** — `type in [:text, :announcement]`, shown with `#` prefix
- **Voice Channels** — `type == :voice`, shown with speaker icon

Each section has its own header and `+` button to open the create channel modal.

### 4. Voice Channel Item Component

**File:** `lib/banter_web/live/chat/components.ex` (`voice_channel_item`)

New component renders voice channels with:
- Speaker SVG icon instead of `#`
- `phx-click="join_voice_channel"` (joins voice, doesn't navigate)
- Highlighted state when user is connected to that channel
- Connected users list indented below the channel name

### 5. Voice Channel User Component

**File:** `lib/banter_web/live/chat/components.ex` (`voice_channel_user`)

Shows each connected user under a voice channel:
- Small avatar with initial
- Username (email prefix)
- Red mute icon if `self_mute` is true
- Red deafen icon if `self_deaf` is true

### 6. Voice Controls Panel

**File:** `lib/banter_web/live/chat/components.ex` (`voice_controls`)

New component rendered between channel list and user info bar when connected to a voice channel:
- Green "Voice Connected" label with channel name
- Disconnect button (turns red on hover)
- Mute toggle — normal state: microphone icon on dark background; muted: red background with crossed-out mic
- Deafen toggle — normal state: speaker icon on dark background; deafened: red background with crossed-out speaker

### 7. Voice Event Handlers

**File:** `lib/banter_web/live/chat/chat_live.ex`

Four new `handle_event` clauses:

| Event | Action |
|-------|--------|
| `"join_voice_channel"` | Leaves current voice channel (if any), creates VoiceState via `Chat.join_voice_channel/1`, broadcasts `:join` to guild PubSub |
| `"leave_voice_channel"` | Destroys VoiceState via `Chat.leave_voice_channel/1`, broadcasts `:leave`, clears assigns |
| `"toggle_voice_mute"` | Toggles `self_mute` on VoiceState, broadcasts `:update` |
| `"toggle_voice_deafen"` | Toggles `self_deaf` (and force-mutes when deafening), broadcasts `:update` |

### 8. PubSub Handler for Voice State Updates

**File:** `lib/banter_web/live/chat/chat_live.ex`

New `handle_info` clause for `{:guild_event, {:voice_state_update, %{action: action, voice_state: vs}}}`:

- `:join` — Adds voice state to `@voice_states` map (deduplicates by user_id)
- `:leave` — Removes voice state from map, cleans up empty channel entries
- `:update` — Replaces voice state in map (mute/deaf changes)

If the event concerns the current user, also updates `@current_voice_channel`, `@voice_muted`, `@voice_deafened`.

### 9. Create Channel Modal Updated

**File:** `lib/banter_web/live/chat/components.ex` (`create_channel_modal`)

Added channel type radio buttons before the name input:
- **Text** (default, checked) — `#` icon
- **Voice** — speaker icon

Both use `has-[:checked]` CSS for highlighted selection state.

**File:** `lib/banter_web/live/chat/chat_live.ex` (`handle_event("create_channel", ...)`)

Passes `type: channel_type` (atom) to `GuildServer.create_channel/4`.

### 10. GuildServer Updated

**File:** `lib/banter/guild_server.ex`

`create_channel/3` → `create_channel/4` with optional keyword `opts`:

```elixir
def create_channel(server_id, user_id, name, opts \\ [])
```

Passes `type: Keyword.get(opts, :type, :text)` to `Chat.create_channel/1`.

### 11. Disconnect Cleanup

**File:** `lib/banter_web/live/chat/chat_live.ex` (`terminate/2`)

When a LiveView process terminates (tab close, navigation away), if the user is in a voice channel:
1. Fetches their voice state from DB
2. Destroys the VoiceState record
3. Broadcasts `:leave` event to guild PubSub

This ensures stale voice states don't persist after disconnection.

### 12. Helper: `maybe_leave_current_voice/1`

**File:** `lib/banter_web/live/chat/chat_live.ex` (private)

Shared helper used by both `join_voice_channel` (to leave the old channel first) and `leave_voice_channel`. Handles:
- Looking up the user's current voice state
- Destroying the record
- Broadcasting the leave event
- Clearing voice-related assigns

---

## Files Changed

| File | Action |
|------|--------|
| `lib/banter_web/live/chat/chat_live.ex` | Modified — voice assigns, 4 event handlers, PubSub handler, terminate cleanup, helper |
| `lib/banter_web/live/chat/components.ex` | Modified — split channel list, 3 new components, updated create modal |
| `lib/banter/guild_server.ex` | Modified — `create_channel/4` accepts type option |

---

## PubSub Event Format

All voice events broadcast on the existing `"guild:#{guild_id}"` topic:

```elixir
{:guild_event, {:voice_state_update, %{
  action: :join | :leave | :update,
  voice_state: %VoiceState{user: %User{}, ...}
}}}
```

---

## What's NOT Included (Phase 3+)

- No actual audio/video — clicking "Join" creates the database record and UI state, but no WebRTC media connection is established yet
- No Membrane RTC Engine pipeline — that's Phase 3
- No client-side JavaScript WebRTC code — that's Phase 4

---

## Next: Phase 3 — Membrane RTC Engine Integration

See [VOICE_VIDEO_GUIDE.md](VOICE_VIDEO_GUIDE.md) for the full implementation plan.
