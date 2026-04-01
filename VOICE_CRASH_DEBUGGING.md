# Voice Pipeline — Crash Debugging Log

**Date:** 2026-02-20
**Context:** Discovered during first real two-device test (phone + laptop, same voice channel)
**Files changed:** `lib/banter/voice/pipeline.ex`, `lib/banter_web/live/chat/chat_live.ex`

---

## Overview

Three distinct bugs were found and fixed in sequence. Each one unmasked the next. The bugs share a common theme: **race conditions between Membrane's async cleanup lifecycle and our GenServer message queue**.

---

## Bug 1 — "no process" on Player LiveView mount

### Symptom

```
[error] GenServer #PID<0.1994.0> terminating
** (stop) exited in: GenServer.call(#PID<0.1904.0>, {:register_peer, ...}, 5000)
    ** (EXIT) no process
```

The `Membrane.WebRTC.Live.Player` LiveView crashed on mount when trying to call `Signaling.register_peer`.

### Root Cause

`Membrane.WebRTC.Signaling` is a GenServer that acts as a one-shot message broker between two peers (the Elixir element and the browser). Its `handle_info({:DOWN, ...})` stops the process whenever **either** peer dies:

```elixir
# deps/membrane_webrtc_plugin/lib/membrane_webrtc/signaling.ex:164-168
def handle_info({:DOWN, _monitor, :process, pid, reason}, state) do
  {peer, _other_peer} = get_peers(pid, state)
  reason = if peer.is_element, do: reason, else: :normal
  {:stop, reason, state}   # ← stops itself when any monitored peer dies
end
```

`ExWebRTCSink` calls `Signaling.register_element(signaling)` in `handle_setup`, which makes the Signaling monitor the Sink. If the Sink's ICE connection fails (`:connection_failed`), the Sink terminates. The Signaling gets `:DOWN`, and stops itself. By the time the Player LiveView mounts and calls `register_peer`, the signaling process is dead.

### Fix

Monitor both signalings from `ChatLive` (`socket.assigns[:voice_monitor_refs]`). On `:DOWN`:
1. Demonitor remaining refs immediately (to de-duplicate if both signalings die)
2. Call `setup_voice_webrtc` again — `Voice.Room.join` creates fresh signalings
3. The Player LiveView's retry picks up the new signaling via the `parent_handshake` mechanism (reads parent's current assigns, not the stale session data)
4. Demonitor on intentional leave to prevent spurious re-setup

**File:** `lib/banter_web/live/chat/chat_live.ex`

---

## Bug 2 — "Trying to remove children while they do not exist" (Membrane.ParentError)

### Symptom

```
** (Membrane.ParentError) Trying to remove children {:sink, "0a9b76c8-...", ref},
while such children or children groups do not exist.
```

The pipeline crashed immediately after Bug 1's reconnect mechanism triggered.

### Root Cause

When a crash group fires (`crash_group_mode: :temporary`), Membrane **synchronously removes** the crashed group's children from the pipeline before calling `handle_crash_group_down`. Meanwhile, the `:DOWN` signal from the signaling process triggered `setup_voice_webrtc` in `ChatLive`, which called `Voice.Room.join`, which sent `{:remove_participant, user_id}` to the pipeline. The pipeline's `do_remove_participant` then tried to call `remove_children` on all three children — but the Sink was already gone. Membrane raised `ParentError`.

The sequence:
```
1. Sink ICE fails → crash group removes [src, fixer, sink] from pipeline
2. Signaling dies → ChatLive :DOWN fires → Voice.Room.join → {:remove_participant} sent to pipeline
3. handle_info({:remove_participant}) → do_remove_participant → remove_children: [src, fixer, sink]
   ↑ Sink no longer exists → Membrane.ParentError → pipeline crashes
```

### Fix

Two changes:

1. **`do_remove_participant` now takes `ctx` and filters by `ctx.children`:**
   ```elixir
   children_to_remove =
     [{:source, user_id, ref}, {:sink, user_id, ref}, {:fixer, user_id, ref}]
     |> Enum.filter(&Map.has_key?(ctx.children, &1))
   actions = if children_to_remove != [], do: [remove_children: children_to_remove], else: []
   ```
   Only removes children that still exist — crash-group-removed children are already gone.

2. **Removed the explicit `Pipeline.remove_participant` call from `Voice.Room`'s reconnect path.** The `handle_info({:add_participant})` handler already calls `do_remove_participant` internally if the user is still in `participant_refs`. The explicit remove was redundant and introduced a race.

**File:** `lib/banter/voice/pipeline.ex`

---

## Bug 3 — "Attempted to link the following pads more than once" (Membrane.LinkError)

### Symptom

```
** (Membrane.LinkError) Attempted to link the following pads more than once:
pad {Membrane.Pad, :output, "0a9b76c8-..."} of child {:fixer, "158a2c04-...", ref}
```

Appeared during reconnect after Bug 2's fix took effect.

### Root Cause

When User A (speaker) is live and User B (listener) connects, a link is created:

```
fixer_A |> via_out(Pad.ref(:output, user_B_id)) |> ... |> sink_B
```

When User B disconnects (crash group), Membrane removes `sink_B`. However, `fixer_A`'s dynamic output pad `output/"user_B_id"` may linger momentarily — Membrane's pad cleanup is not instantaneous relative to the next `handle_info` in the pipeline's mailbox.

When User B reconnects, `do_add_participant` creates `incoming_audio_links` and tries to link `fixer_A |> via_out(Pad.ref(:output, user_B_id))` again — but Membrane still sees that pad as linked. `Membrane.LinkError` is raised.

### Fix

**Use session-ref–qualified pad names:** `Pad.ref(:output, {listener_id, listener_ref})` instead of `Pad.ref(:output, listener_id)`.

Each join creates a fresh `ref = make_ref()`. Since the ref is unique per session, each reconnect uses a **completely different pad name** on the fixer. Even if the old pad `output/{user_B_id, old_ref}` hasn't been freed yet, the new link uses `output/{user_B_id, new_ref}` — no collision possible.

Two places changed in `pipeline.ex`:

```elixir
# handle_child_notification — egress from speaker's fixer to each listener's sink
|> via_out(Pad.ref(:output, {other_user_id, other_ref}))   # was: other_user_id

# do_add_participant — late-joiner links from existing speakers' fixers to new sink
|> via_out(Pad.ref(:output, {user_id, ref}))                # was: user_id
```

`linked_egress` logical pairs (`{speaker_id, listener_id}`) are unchanged — they track intent, not pad names.

`TimestampFixer` handles tuple pad IDs correctly because `def_output_pad :output, availability: :on_request` accepts any term as the pad reference, and its `handle_pad_added/removed` callbacks use `Pad.ref(:output, _id)` which matches any ID.

**File:** `lib/banter/voice/pipeline.ex`

---

## Bug 4 — Stale Crash Group Kills Reconnected Session (Reconnect Loop)

### Symptom

Discovered during two-device testing: even with Bugs 1-3 fixed, when the phone's ICE failed, both devices ended up hearing nothing. The logs showed:

```
[warning] Participant connection failed (Group: {"0a9b76c8-...", ref_83720})
[info] Removing participant 0a9b76c8   ← removing the WRONG ref!
[debug] Removing children: [fixer_111098, sink_111098, source_111098]  ← new session!
```

### Root Cause

The `handle_crash_group_down` callback receives the group name `{user_id, crashed_ref}`. The original implementation ignored `crashed_ref` and called `do_remove_participant(user_id, ctx, state)`, which **looked up the current ref from `participant_refs`**:

```elixir
# BEFORE — bug:
def handle_crash_group_down(group_name, ctx, state) do
  case group_name do
    {user_id, _ref} ->               # ← _ref discarded!
      do_remove_participant(user_id, ctx, state)  # uses whatever is in participant_refs now
  end
end
```

**Timeline that triggers the bug:**

```
1. User 0a9b76c8 is in room with session ref_83720
2. Sink ICE fails → signaling dies → ChatLive :DOWN fires
3. Voice.Room.join called → pipeline gets {:add_participant, user_id, new_signalings}
4. handle_info({:add_participant}) runs:
   - do_remove_participant(ref_83720) → removes old children
   - do_add_participant → creates new children with ref_111098
   - participant_refs["0a9b76c8"] = ref_111098
5. ** handle_crash_group_down({user_id, ref_83720}) fires for OLD session **
   - Map.get(participant_refs, user_id) = ref_111098  ← NEW ref!
   - Removes [source_111098, fixer_111098, sink_111098]  ← NEW session killed!
6. New session's pipeline children die → signaling dies → :DOWN fires again
7. → Infinite reconnect loop
```

The root cause is that `handle_crash_group_down` fires asynchronously. By the time Membrane finishes cleaning up the old crash group and delivers the callback, the pipeline `handle_info` queue may have already processed the reconnect `{:add_participant}` message and swapped in a new session.

### Fix

Compare the `crashed_ref` from the group name against the **current session's ref** in `participant_refs`. If they differ, the user already reconnected — ignore the stale crash group:

```elixir
def handle_crash_group_down(group_name, ctx, state) do
  case group_name do
    {user_id, crashed_ref} ->
      case Map.get(state.participant_refs, user_id) do
        ^crashed_ref ->
          do_remove_participant(user_id, ctx, state)   # same session → clean up

        other_ref ->
          Logger.debug("ignoring stale crash group for #{user_id} " <>
            "(crashed=#{inspect(crashed_ref)}, current=#{inspect(other_ref)})")
          {[], state}                                   # different session → skip
      end
    _ ->
      {[], state}
  end
end
```

**File:** `lib/banter/voice/pipeline.ex`

---

## Additional Fix — Pipeline Ignoring Configured ICE Servers

### Problem

`pipeline.ex` was hardcoding `ice_servers = [%{urls: "stun:stun.l.google.com:19302"}]` even though `Voice.Room.start_pipeline/1` correctly reads the configured servers from `Application.get_env(:banter, :webrtc)` and passes them as `opts`.

This meant TURN servers configured in `dev.exs` were silently ignored on the Elixir side.

### Fix

```elixir
# BEFORE:
ice_servers = [%{urls: "stun:stun.l.google.com:19302"}]

# AFTER:
ice_servers = Keyword.get(opts, :ice_servers, [%{urls: "stun:stun.l.google.com:19302"}])
```

**File:** `lib/banter/voice/pipeline.ex`

---

## ICE Connectivity — Same-LAN vs Cross-Network

### Observations from Testing

- **Laptop (same LAN as server):** ICE connects via local host candidates (`192.168.1.31`). Works reliably with STUN only.
- **Phone (different network):** Shows `100.80.250.233` as host candidate (not a LAN IP — likely mobile data or VPN/hotspot overlay). `196.159.69.30` as srflx. Different public IP from server (`41.237.101.181`). ICE fails without TURN.

### Diagnosis Signs

- If the phone's host candidate is NOT in `192.168.1.x`, it's not on the server's LAN.
- If srflx candidate has a different public IP than the server's srflx, ICE hole-punching will likely fail.
- `Couldn't resolve c29843f1-2eed-466b-849e-ee35be4c98b6.local, reason: ehostunreach` — mDNS names (used by Chrome for privacy) cannot be resolved on the Elixir server side. This is expected; srflx fallback is used.
- `No transaction to execute. Did Ta timer fired without the need?` — repeated ICE keep-alive timers firing without a valid pair to check. Indicates ICE is in `checking` state with no viable path.

### Solution for Cross-Network (TURN)

1. Get free TURN credentials (e.g., [metered.ca](https://www.metered.ca/stun-turn))
2. Add to `config/dev.exs`:
   ```elixir
   config :banter, :webrtc,
     ice_servers: [
       %{urls: "stun:stun.l.google.com:19302"},
       %{
         urls: ["turn:global.relay.metered.ca:80", "turns:global.relay.metered.ca:443?transport=tcp"],
         username: "YOUR_USERNAME",
         credential: "YOUR_CREDENTIAL"
       }
     ]
   ```
3. Also add TURN to the JS side in `assets/js/hooks.js` (same credentials):
   ```javascript
   const iceServers = [
     { urls: "stun:stun.l.google.com:19302" },
     { urls: ["turn:global.relay.metered.ca:80", ...], username: "...", credential: "..." }
   ]
   ```

Both sides (Elixir pipeline + JS PeerConnection) must use TURN for cross-network calls to work.

---

## Lessons Learned

| # | Lesson |
|---|--------|
| 1 | `Membrane.WebRTC.Signaling` is a **one-shot broker** — it stops itself when either peer dies. Don't assume signalings outlive their connected element. |
| 2 | `handle_crash_group_down` fires **asynchronously** after the children are removed. By the time it fires, `participant_refs` may already reflect a new session. Always validate `crashed_ref == current_ref` before acting. |
| 3 | When returning `remove_children` actions, **always filter by `ctx.children`** — crash groups may have already removed some children before `do_remove_participant` runs. |
| 4 | Membrane dynamic pads on surviving elements are not guaranteed to be freed before the next `handle_info` runs. Use **ref-qualified pad names** `{user_id, session_ref}` to make each session's pads unique. |
| 5 | Verify config inheritance: opts passed to `Pipeline.start_link` must be explicitly read in `handle_init` — `Application.get_env` in `handle_init` reads config, but opts are a separate mechanism. Always prefer opts for per-pipeline config (like `ice_servers`) so tests/Room can override them. |
| 6 | For cross-network WebRTC, **both Elixir and JS must configure TURN**. STUN-only works on same-LAN; TURN is required when any peer is behind a different NAT. |
