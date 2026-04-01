# Voice & Video Feature — Implementation Guide

**Status:** Phase 3 Complete (Steps 3-4 done 2026-02-11), Phase 4/5 Next
**Last Updated:** 2026-02-20

---

## Overview

Add Discord-style voice channels and optional video to the Discord Clone using **Membrane Framework** for WebRTC media handling. Membrane is a native Elixir multimedia framework that runs on the BEAM, with deep integration into the Phoenix/OTP/LiveView ecosystem. Signaling is handled through LiveView hooks (no separate Phoenix Channel needed).

---

## Technology Decisions

| Component | Choice | Why |
|-----------|--------|-----|
| Media transport | WebRTC (browser-native) | Free, open standard, built into all browsers |
| SFU (group calls) | Custom routing via `membrane_webrtc_plugin` | Actively maintained, native LiveView integration, pure Elixir |
| WebRTC implementation | ex_webrtc (pure Elixir) | No C NIFs, runs anywhere Elixir runs |
| Signaling | LiveView hooks (Membrane.WebRTC.Live) | Built-in LiveView Capture/Player components, no separate JS SDK |
| STUN | Google public STUN | Free, reliable, no setup needed for dev |
| TURN | Coturn (self-hosted, future) | Free, only needed when peers can't connect directly (~10-20% of cases) |

### Important: Dependency Change from Original Plan

The original plan used `membrane_rtc_engine` as the SFU. **This package was archived in Nov 2025** (moved to fishjam-cloud, no longer maintained). The two viable paths are:

| Approach | Package | Version | Status | Pros | Cons |
|----------|---------|---------|--------|------|------|
| **A (Recommended)** | `membrane_webrtc_plugin` | 0.26.2 (Jan 2026) | **Actively maintained** | Native LiveView components, pure Elixir, no JS SDK needed | Must build own SFU routing logic |
| B (Original) | `membrane_rtc_engine` | 0.25.0 (Nov 2025) | **Archived** | Built-in SFU with track management | Dead project, uses separate JS SDK |

**Recommendation: Approach A** — `membrane_webrtc_plugin` with custom routing GenServer. Reasons:
- Actively maintained (latest release Jan 2026)
- Native Phoenix LiveView integration (`Membrane.WebRTC.Live.Capture` / `Player`)
- No npm dependency on a separate JS SDK — LiveView hooks handle signaling
- Pure Elixir stack (ex_webrtc under the hood, no C NIFs)
- Multi-peer routing built with a GenServer managing one pipeline per peer

### Cost Summary
- **Development:** $0 — everything runs locally, no Docker containers needed
- **Production:** Only server hosting costs (no per-minute API fees, no separate SFU service)

---

## Architecture

### With Custom SFU (Group Calls)

```
User A ----\                                    /---- User C
             \                                /
User B -------> VoiceRoom GenServer <------------ User D
             /   (manages pipelines)          \
User E ----/                                    \---- User F

Each user has a Membrane pipeline with WebRTC Source (receiving their audio).
VoiceRoom routes each user's audio to all other participants via WebRTC Sinks.
Runs as supervised OTP processes — no external service.
```

### Integration with Existing Architecture

```
lib/banter/
├── voice/                          # Voice domain
│   ├── room.ex                     # GenServer per voice channel (manages pipeline lifecycle)
│   └── pipeline.ex                 # Membrane Pipeline (SFU audio routing)
lib/banter_web/
├── live/
│   └── chat/
│       ├── chat_live.ex            # MODIFIED: Voice assigns, event handlers, PubSub
│       └── components.ex           # MODIFIED: Voice channel UI, controls
assets/js/
├── hooks.js                        # MODIFY: Add Membrane Capture/Player hooks
```

---

## Implementation Phases

### Phase 1: Voice Channel Data Model — COMPLETE

See [VOICE_PHASE1_COMPLETE.md](VOICE_PHASE1_COMPLETE.md) for details.

- VoiceState Ash resource (transient, hard-delete on leave)
- Membrane deps in mix.exs (need to swap — see Phase 3)
- VoiceRoomRegistry + VoiceRoomSupervisor in application.ex
- ICE server config in `config/dev.exs`
- Migration: `voice_states` table with unique user constraint

### Phase 2: Voice Channel UI — COMPLETE

See [VOICE_PHASE2_COMPLETE.md](VOICE_PHASE2_COMPLETE.md) for details.

- Channel list split into Text Channels / Voice Channels sections
- Voice channels render with speaker icon, text channels with `#`
- Connected users shown under each voice channel (avatar, name, mute/deaf indicators)
- Voice controls panel: "Voice Connected" status, disconnect, mute, deafen buttons
- Join/leave/mute/deafen event handlers with PubSub broadcast
- Create channel modal with Text/Voice type radio selection

**Key Pattern — PubSub as single source of truth for voice state:**
```
Event handlers: ONLY do DB operation + PubSub.broadcast (NO local assign changes)
PubSub handle_info: the SINGLE place that updates all voice-related assigns
```

This ensures all LiveView processes (including the sender) update state consistently through one code path.

**LiveView assigns:**
```elixir
@voice_states           # %{channel_id => [%VoiceState{}, ...]}
@current_voice_channel  # channel struct or nil
@voice_muted            # boolean
@voice_deafened         # boolean
```

**Known Bug — Page Refresh Clears Voice State:**
When a user refreshes their browser tab, the old LiveView's `terminate/2` fires and destroys their VoiceState from the database + broadcasts `:leave`. By the time the new LiveView mounts and calls `load_server/2`, the voice state is already gone from DB. Other users also see the user disappear momentarily.

**Fix approach (Phase 2.5):**
- Option A: Add a grace period — `terminate/2` schedules a delayed cleanup (e.g., 5s via `Process.send_after` to a cleanup GenServer) instead of immediately destroying. On mount, cancel the pending cleanup if the same user reconnects. This handles page refresh without kicking the user out.
- Option B: Don't clean up voice state in `terminate/2` at all. Instead, use an Oban cron job to periodically sweep stale voice states (users whose Presence is no longer tracked). The `load_server/2` DB bootstrap handles showing correct state on mount.
- Option C (simplest): On `terminate/2`, only untrack Presence but DON'T destroy the VoiceState. On mount, check DB for existing voice state and restore it. Add a periodic cleanup (Oban or GenServer timer) that removes voice states for users with no active Presence entry after a timeout.

---

### Phase 2.5: Fix Page Refresh Bug — COMPLETE

**Goal:** Users stay in voice channels across page refreshes.

**Approach (Option C — simplest):**

1. **Removed voice state cleanup from `terminate/2`** — `terminate/2` no longer destroys VoiceState records. It only untracks Presence (which reconnects naturally on mount).

2. **Voice state restored on mount** — `load_server/2` loads voice states from DB and restores `@current_voice_channel`, `@voice_muted`, `@voice_deafened` for the current user.

3. **VoiceCleanupWorker (Oban cron)** — Runs every 60s, finds VoiceState records where the user has no active Presence entry, destroys them, and broadcasts `:leave`. Handles genuine disconnects (tab closed permanently, network loss, browser crash).

**Additional bug fixed — `list_voice_states_for_server` returning empty:**
The convenience wrappers `list_voice_states_for_server` and `list_voice_states_for_channel` were calling Ash code interface functions with maps (`%{server_id: id}`) when those functions expected positional args (because they were defined with `args: [:server_id]`). This caused the DB query to silently fail and return `[]`. Voice states only appeared via PubSub events, never from DB bootstrap. Fixed by passing positional args directly.

**Files changed:**
| File | Change |
|------|--------|
| `lib/banter_web/live/chat/chat_live.ex` | Removed voice state destruction from `terminate/2` |
| `lib/banter/workers/voice_cleanup_worker.ex` | **New** — Oban worker to sweep stale voice states |
| `config/config.exs` | Added Oban crontab entry: `"* * * * *"` for VoiceCleanupWorker |
| `lib/banter/chat.ex` | Added `list_all_voice_states` define; fixed positional arg calls in `list_voice_states_for_server/1` and `list_voice_states_for_channel/1` |

---

### Phase 3: Membrane WebRTC Plugin Integration (Server Side)

**Goal:** Actual audio transmission between users in voice channels using `membrane_webrtc_plugin`.

**Step 1: Swap Dependencies — COMPLETE**

Replaced the archived `membrane_rtc_engine` deps with the actively maintained `membrane_webrtc_plugin`:

```elixir
# mix.exs — REMOVED:
{:membrane_rtc_engine, "~> 0.23.0"},
{:membrane_rtc_engine_webrtc, "~> 0.9.0"},
{:bundlex, "~> 1.5", override: true}

# mix.exs — ADDED:
{:membrane_webrtc_plugin, "~> 0.26.2"}
```

Required `mix deps.clean --unused --unlock` before `mix deps.get` to clear stale lock entries.

No separate npm package needed — `membrane_webrtc_plugin` includes JS hooks for LiveView.

**Step 2: Voice Room GenServer + Pipeline — COMPLETE**

Created two modules:

**`lib/banter/voice/room.ex`** — One GenServer per active voice channel. Manages Membrane pipeline lifecycle, creates signaling channels per participant.

API:
```elixir
Voice.Room.join(channel_id, user_id)         # => {:ok, %{ingress: signaling, egress: signaling}}
Voice.Room.leave(channel_id, user_id)        # => :ok
Voice.Room.get_signalings(channel_id, user_id) # => {:ok, %{ingress: s, egress: s}} | :error
Voice.Room.participants(channel_id)          # => [user_id, ...]
Voice.Room.ensure_started(channel_id)        # => {:ok, pid}
```

Key design:
- Follows GuildServer pattern (Registry + DynamicSupervisor + idle timeout)
- 5-minute idle timeout (vs GuildServer's 30 min)
- Creates `Membrane.WebRTC.Signaling.new()` per participant (ingress + egress)
- Monitors pipeline process, recovers from crashes
- Stops pipeline when room becomes empty

**`lib/banter/voice/pipeline.ex`** — `Membrane.Pipeline` for SFU audio routing.

Key design:
- Each participant has a `Membrane.WebRTC.Source` (ingress — receives mic audio) and `Membrane.WebRTC.Sink` (egress — sends audio to browser)
- On join: links existing Sources to new Sink (so new user hears others) + links new Source to existing Sinks (so others hear new user)
- On leave: removes Source + Sink children (Membrane auto-cleans linked pads)
- Uses `send/2` to communicate with pipeline (not `notify_child` which is undefined in this membrane_core version)
- Tracks participants via MapSet

**Step 3: Signaling via LiveView**

The `membrane_webrtc_plugin` provides `Membrane.WebRTC.Live.Capture` and `Membrane.WebRTC.Live.Player` LiveView components with built-in hooks. Signaling flows through the LiveSocket automatically — no Phoenix Channel needed.

```elixir
# In ChatLive mount, when user joins voice:
ingress_signaling = Membrane.WebRTC.Signaling.new()
# Pass signaling to Voice.Room, which creates the pipeline
Voice.Room.join(channel_id, user_id, ingress_signaling)
# Attach Capture component to LiveView socket
socket = Membrane.WebRTC.Live.Capture.attach(socket,
  id: "voice-capture",
  signaling: ingress_signaling,
  audio?: true,
  video?: false
)
```

**Step 4: Audio Pipeline Architecture**

For N participants in a voice channel:
```
Participant A:
  Source Pipeline: Browser mic → WebRTC Source → audio buffers
  Sink Pipelines:  audio from B → WebRTC Sink → Browser speaker
                   audio from C → WebRTC Sink → Browser speaker

Participant B:
  Source Pipeline: Browser mic → WebRTC Source → audio buffers
  Sink Pipelines:  audio from A → WebRTC Sink → Browser speaker
                   audio from C → WebRTC Sink → Browser speaker

Voice.Room GenServer orchestrates creating/destroying these pipelines.
```

**Key Membrane modules used:**
```elixir
Membrane.WebRTC.Source       # Receive audio from browser
Membrane.WebRTC.Sink         # Send audio to browser
Membrane.WebRTC.Signaling    # Create signaling channels
Membrane.WebRTC.Live.Capture # LiveView component for browser mic capture
Membrane.WebRTC.Live.Player  # LiveView component for browser audio playback
```

**Files changed (Steps 1-2 — DONE):**

| File | Action | Status |
|------|--------|--------|
| `mix.exs` | Swapped membrane deps | DONE |
| `lib/banter/voice/room.ex` | New — Voice room GenServer | DONE |
| `lib/banter/voice/pipeline.ex` | New — Membrane pipeline for audio routing | DONE |

**Files changed (Steps 3-4 — DONE):**

| File | Action | Status |
|------|--------|--------|
| `lib/banter_web/live/chat/chat_live.ex` | Added Voice.Room.join, Capture/Player attach, signaling monitors, :DOWN reconnect handler | DONE |
| `lib/banter_web/live/chat/components.ex` | Render Capture/Player components in voice area | DONE |
| `assets/js/hooks.js` | Custom Capture hook (audio processing pipeline), Player hook (unmute on mount), VoiceControls hook | DONE |

---

### Phase 4: Client-Side Integration (LiveView Hooks + JS)

**Goal:** Browser mic capture and remote audio playback via LiveView hooks.

**Step 1: Add Membrane JS Hooks**

```javascript
// assets/js/hooks.js
import { createCaptureHook, createPlayerHook } from "membrane_webrtc_plugin";

const iceServers = [{ urls: "stun:stun.l.google.com:19302" }];

// Add to existing Hooks object
Hooks.Capture = createCaptureHook(iceServers);
Hooks.Player = createPlayerHook(iceServers);
```

No separate `voice.js` file needed — the Membrane plugin provides the hooks.

**Step 2: LiveView Template Integration**

```heex
<%!-- When user is in a voice channel, render Capture + Player components --%>
<%= if @current_voice_channel do %>
  <Membrane.WebRTC.Live.Capture.live_render socket={@socket} capture_id="voice-capture" />

  <%!-- One Player per remote participant --%>
  <%= for {peer_id, player_id} <- @voice_players do %>
    <Membrane.WebRTC.Live.Player.live_render socket={@socket} player_id={player_id} />
  <% end %>
<% end %>
```

These components are invisible (audio-only) — they just establish WebRTC connections.

**Step 3: Mute/Deafen Integration**

- **Mute:** Disable the local audio track via JS hook (`track.enabled = false`). The Capture component continues the WebRTC connection but sends silence.
- **Deafen:** Mute all Player audio elements (`audio.muted = true`). The WebRTC connections stay active but audio output is suppressed.
- Both states are already tracked in `@voice_muted` / `@voice_deafened` assigns and synced via PubSub.

**Files to modify:**

| File | Action |
|------|--------|
| `assets/js/hooks.js` | Add Membrane Capture/Player hooks |
| `assets/js/app.js` | Import hooks (may already be set up) |
| `lib/banter_web/live/chat/chat_live.ex` | Attach Capture/Player on join, push mute/deafen events to hooks |
| `lib/banter_web/live/chat/components.ex` | Render Capture/Player components in voice channel area |

---

### Phase 5: Polish & Edge Cases

**Goal:** Production-ready voice with proper error handling and UX.

**Items:**
1. **Graceful error handling** — mic permission denied, WebRTC connection failure, pipeline crashes
2. **Voice activity detection** — show speaking indicator (green ring around avatar) using WebRTC audio level API
3. **Automatic reconnection** — if Membrane pipeline crashes, OTP supervisor restarts it; LiveView re-attaches hooks
4. **Multiple servers** — ensure voice state is properly managed when user switches between servers
5. **Mobile browser support** — test getUserMedia on iOS Safari, Android Chrome
6. **Oban cleanup worker** — finalize the stale voice state cleanup from Phase 2.5

---

## Local Development Setup

### Prerequisites
- Elixir 1.15+, Phoenix 1.8+
- No Docker needed — Membrane runs as part of the Elixir app
- No external accounts or API keys needed
- OpenSSL headers on macOS (for ex_webrtc TLS):
  ```bash
  brew install openssl@3
  ```

### Steps
```bash
# 1. Install Elixir deps
mix deps.get

# 2. No separate JS install needed — membrane_webrtc_plugin hooks
#    are available via the Elixir package

# 3. Start the server
mix phx.server
```

### Configuration (config/dev.exs)

**Same-LAN (default, STUN only):**
```elixir
config :banter, :webrtc,
  ice_port_range: 50000..50050,
  external_ip: "192.168.1.x",  # auto-detected via get_local_ip helper
  ice_servers: [%{urls: "stun:stun.l.google.com:19302"}]
```

**Cross-network (phone on mobile data, remote device — requires TURN):**
```elixir
config :banter, :webrtc,
  ice_port_range: 50000..50050,
  external_ip: "your.server.ip",
  ice_servers: [
    %{urls: "stun:stun.l.google.com:19302"},
    %{
      urls: [
        "turn:global.relay.metered.ca:80",
        "turn:global.relay.metered.ca:80?transport=tcp",
        "turns:global.relay.metered.ca:443?transport=tcp"
      ],
      username: "YOUR_METERED_USERNAME",
      credential: "YOUR_METERED_CREDENTIAL"
    }
  ]
```

Also update the JS side in `assets/js/hooks.js` — `iceServers` const must match.

Free TURN credentials: [metered.ca](https://www.metered.ca/stun-turn)

> **Note:** Both Elixir pipeline and JS PeerConnection must configure TURN. Configuring only one side is insufficient.

### Testing Voice Locally
- Open two browser tabs logged in as different users
- Both join the same voice channel
- You'll hear your own mic feedback (use headphones or mute one tab)
- For phone + laptop testing, ensure both are on the same WiFi as the dev server (or use TURN)

---

## Patterns to Follow

These match existing codebase conventions:

| Pattern | Existing Example | Voice Equivalent |
|---------|-----------------|-----------------|
| GenServer per entity | `GuildServer` | `Voice.Room` — one process per active voice channel |
| Registry lookup | `{:guild, guild_id}` | `VoiceRoomRegistry` |
| DynamicSupervisor | `VoiceRoomSupervisor` (already in application.ex) | Supervise Voice.Room processes |
| PubSub broadcast | `"guild:#{guild_id}"` | Reuse guild topic for voice state events |
| Ash resource | `Chat.Message` | `Chat.VoiceState` (already created) |
| PubSub single source of truth | voice event handlers | DB op + broadcast only, PubSub handler updates assigns |
| Oban worker | `VoiceCleanupWorker` | Sweep stale voice states (cron, every 60s) |

---

## PubSub Event Format

All voice events broadcast on the existing `"guild:#{guild_id}"` topic:

```elixir
{:guild_event, {:voice_state_update, %{
  action: :join | :leave | :update,
  voice_state: %VoiceState{user: %User{}, ...}
}}}
```

**Voice handler pattern:**
```
handle_event("join/leave/mute/deafen")
  → DB operation (create/destroy/update VoiceState)
  → PubSub.broadcast(:voice_state_update)
  → return {:noreply, socket}  # NO local assign changes

handle_info({:guild_event, {:voice_state_update, ...}})
  → Update @voice_states, @current_voice_channel, @voice_muted, @voice_deafened
  → This is the SINGLE place assigns change
```

---

## Key Design Decisions

### Why `membrane_webrtc_plugin` over `membrane_rtc_engine`?
- `membrane_rtc_engine` was **archived Nov 2025** — no future updates or bug fixes
- `membrane_webrtc_plugin` is **actively maintained** (v0.26.2, Jan 2026)
- Native LiveView integration — `Capture` and `Player` components with built-in hooks
- No separate JS SDK npm package needed
- Pure Elixir (ex_webrtc) — no C NIFs for ICE/DTLS

### Why not a Phoenix Channel for signaling?
- `membrane_webrtc_plugin` provides `Membrane.WebRTC.Live.Capture/Player` components
- Signaling flows through the LiveSocket automatically
- One less moving part — no separate Channel module to maintain

### Voice channel vs text channel
- Same Channel resource, differentiated by `channel_type` attribute
- Voice channels show connected users instead of message history
- Text chat in voice channels is a future extension

---

## Oban Integration

- **Voice session cleanup** — Cron job (every 60s) to clear stale voice states where user has no active Presence
- **Voice usage analytics** — Background job to log voice channel usage duration (future)
- **Recording processing** — If recording is added, Membrane can dump media to files; Oban processes/transcodes (future)

---

## Future Extensions (Out of Scope for Initial Implementation)

- Screen sharing (Membrane supports additional track types)
- Video grid layout for video calls
- Push-to-talk mode
- Voice activity detection indicators (speaking animation)
- Server-side recording (Membrane can write to MP4/MKV)
- Noise suppression (via WebRTC audio processing)
- Server-side audio mixing (Membrane pipeline model)

---

## Related Documents

- [VOICE_CRASH_DEBUGGING.md](VOICE_CRASH_DEBUGGING.md) — Deep-dive into the four pipeline crash bugs found during 2-device testing (root causes, fixes, lessons)
- [VOICE_PHASE1_COMPLETE.md](VOICE_PHASE1_COMPLETE.md) — Phase 1 completion notes (data model, deps)
- [VOICE_PHASE2_COMPLETE.md](VOICE_PHASE2_COMPLETE.md) — Phase 2 completion notes (UI, PubSub)

## Reference Links

- [Membrane Framework](https://membrane.stream/)
- [membrane_webrtc_plugin (Hex)](https://hex.pm/packages/membrane_webrtc_plugin)
- [membrane_webrtc_plugin (API docs)](https://hexdocs.pm/membrane_webrtc_plugin/)
- [ex_webrtc — Pure Elixir WebRTC](https://github.com/elixir-webrtc/ex_webrtc)
- [Membrane GitHub](https://github.com/membraneframework)
- [Membrane Demo — webrtc_live_view](https://github.com/membraneframework/membrane_demo/tree/master/webrtc_live_view)
- [MDN WebRTC API](https://developer.mozilla.org/en-US/docs/Web/API/WebRTC_API)
- [Coturn TURN Server](https://github.com/coturn/coturn)

---

## Session Notes

### 2026-02-10: Phase 2 Bug Fix — Voice State Sync
**Problem:** When user A joined a voice channel, user A's UI would only show themselves (not other users already in the channel). Meanwhile, user B's UI would correctly show both users.

**Root cause:** Event handlers were doing local assign updates AND broadcasting. The local update was incomplete (only added the new user), then the PubSub handler fired and could overwrite state.

**Fix:** Simplified to "PubSub as single source of truth" pattern:
- Event handlers: ONLY do DB operation + `PubSub.broadcast` — zero local assign changes
- PubSub `handle_info`: the SINGLE place that updates all voice assigns
- Both the sender and all other LiveView processes update through the same PubSub handler

### 2026-02-10: Known Bug — Page Refresh
When refreshing the page, `terminate/2` destroys the user's VoiceState before the new LiveView mounts. Fix planned for Phase 2.5 (see above).

### 2026-02-11: Phase 2.5 Complete — Page Refresh Bug Fixed
**Two bugs fixed:**

1. **terminate/2 destroying voice state on refresh** — Removed voice state destruction from `terminate/2`. Added `VoiceCleanupWorker` (Oban cron, every 60s) to sweep stale voice states where the user has no active Presence entry. This is the project's first Oban worker.

2. **`load_server/2` not loading voice states from DB** — `list_voice_states_for_server` and `list_voice_states_for_channel` were calling Ash code interface functions with maps (`%{server_id: id}`) instead of positional args. The functions were defined with `args: [:server_id]`, so the map was treated as the UUID value, causing a type mismatch and silent `{:error, _} -> []` return. Voice states only ever appeared via PubSub real-time updates, never from DB bootstrap on mount.

**Ash Gotcha — Code Interface `args` calling convention:**
- `define :my_func, args: [:foo], action: :bar` → call as `my_func(foo_value)` (positional)
- `define :my_func, action: :bar` (no args) → call as `my_func(%{foo: foo_value})` (map)
- Mixing these up (passing a map to a positional-args function) silently fails — the map becomes the argument value, type-check fails, error is swallowed.

### 2026-02-11: Phase 3 Steps 1-2 Complete — Server-Side Voice Infrastructure

**Step 1 — Dep swap:**
- Removed `membrane_rtc_engine ~> 0.23.0`, `membrane_rtc_engine_webrtc ~> 0.9.0`, `bundlex ~> 1.5 (override)`
- Added `membrane_webrtc_plugin ~> 0.26.2`
- Had to run `mix deps.clean --unused --unlock` first — the lock file had stale entries from old deps that conflicted with new dep's requirements

**Step 2 — Voice.Room + Pipeline:**
- Created `lib/banter/voice/room.ex` — GenServer per active voice channel
- Created `lib/banter/voice/pipeline.ex` — Membrane Pipeline for SFU audio routing
- Initially used `Membrane.Pipeline.notify_child/3` which turned out to be undefined in this version of membrane_core; switched to `send/2` instead
- Pipeline dynamically adds Source/Sink children and links them for N-way audio routing

**Gotcha — `Membrane.Pipeline.notify_child/3`:**
This function doesn't exist in the membrane_core version pulled by membrane_webrtc_plugin. Use `send(pipeline_pid, message)` and handle in `handle_info/3` instead.

### 2026-02-11: Phase 3 Steps 3-4 Complete — Client-Side WebRTC Integration

**Step 3 — LiveView signaling:**
- Added `setup_voice_webrtc/2` helper in ChatLive: calls `Voice.Room.join`, attaches `Capture` and `Player` components, pushes mute/deafen state to JS
- Added `maybe_leave_current_voice/1` helper: updates DB, calls `Voice.Room.leave`, removes Membrane components
- Voice assigns (`@current_voice_channel`, `@voice_muted`, `@voice_deafened`) persist when user switches servers
- `load_server` only sets `@voice_states` for display; voice assigns are managed separately

**Step 4 — JS hooks:**
- Custom `Capture` hook in `hooks.js`: inserts `VoiceAudioProcessor` (highpass → lowpass → gate → compressor) between `getUserMedia` and the WebRTC PeerConnection. Enables `echoCancellation`, `noiseSuppression`, `autoGainControl`.
- `Player` hook: wraps `createPlayerHook` from membrane_webrtc_plugin, unmutes element after mount (autoplay policy requires user gesture before unmute — the "Join Voice" click satisfies this).
- `VoiceControls` hook: handles `voice_mute_changed` and `voice_deafen_changed` events from LiveView by toggling track `enabled` and element `muted`.

**Gotcha — Player autoplay policy:**
The `<video muted>` attribute is required for autoplay in browsers. The Player LiveView renders with `muted` by default. The JS `Player` hook explicitly calls `this.el.muted = false` after mount because the user already interacted with the page via "Join Voice" button click, satisfying autoplay policy.

**Gotcha — Signaling Cascade Crash:**
`Signaling.new()` uses `GenServer.start_link` which links the signaling to its caller (Voice.Room). `Pipeline.start_link` also links the pipeline supervisor to Voice.Room. If any pipeline element crashes, EXIT signals cascade and kill Voice.Room, which kills all signalings, which crashes all Capture/Player LiveViews with "no process".
- Fix 1: `Process.flag(:trap_exit, true)` in `Voice.Room.init` — absorbs EXIT signals
- Fix 2: `Process.unlink(signaling.pid)` after `Signaling.new()` — decouples signaling lifecycles from Voice.Room
- Fix 3: `handle_info({:EXIT, ...})` handler in Voice.Room for pipeline exits
- Fix 4: `try/catch` in `setup_voice_webrtc` — prevents LiveView crash if `Voice.Room.join` fails

### 2026-02-20: Pipeline Crash Bug Deep-Dive

Four crash bugs found and fixed during first real two-device test. See [VOICE_CRASH_DEBUGGING.md](VOICE_CRASH_DEBUGGING.md) for full root cause analysis.

**Summary:**

| Bug | Symptom | Root Cause | Fix |
|-----|---------|------------|-----|
| 1 | `(EXIT) no process` on Player mount | `Signaling` stops itself when Sink ICE fails; Player mounts after signaling is dead | Monitor signalings in ChatLive; on `:DOWN`, re-call `setup_voice_webrtc` with fresh signalings |
| 2 | `Membrane.ParentError: Trying to remove children while they do not exist` | Crash group removes Sink; `do_remove_participant` then returns `remove_children` for already-gone children | Filter `remove_children` by `ctx.children` to only remove still-existing children |
| 3 | `Membrane.LinkError: Attempted to link pads more than once` | `fixer_A`'s dynamic output pad `output/"user_B"` isn't freed before reconnect tries to re-use it | Qualify pad names with session ref: `Pad.ref(:output, {user_id, session_ref})` — each reconnect uses a unique pad name |
| 4 | Infinite reconnect loop (both devices hear nothing) | `handle_crash_group_down({user_id, old_ref})` fires after user reconnected; `do_remove_participant` used new ref from `participant_refs` and killed the new session | Compare `crashed_ref` against current `participant_refs[user_id]`; skip if stale |

**Additional fix:** Pipeline was hardcoding `ice_servers` in `handle_init`, ignoring the `ice_servers` passed via opts from `Voice.Room`. TURN servers configured in `dev.exs` were silently unused.

### Next Steps — Phase 4/5: Polish & Error Handling
1. Speaking indicators (green ring when user is actively transmitting audio)
2. Graceful mic permission denied handling
3. Visual feedback when ICE fails (show reconnecting state in voice controls UI)
4. Mobile browser testing (iOS Safari `getUserMedia` quirks)
5. TURN server setup for cross-network calls
