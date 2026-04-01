# Heartbeat Monitoring Guide

## Quick Start

### Method 1: Enable Debug Logging (Recommended)

```bash
# Start with debug logs enabled
LOGGER_LEVEL=debug mix phx.server
```

Or in `config/dev.exs`, add:
```elixir
config :logger, level: :debug
```

### Method 2: Runtime Debug Enable

```bash
# Start server normally
iex -S mix phx.server

# In IEx console:
Logger.configure(level: :debug)
```

## What You'll See

### 1. Session Startup
```
[info] 🚀 Starting Session for session_id=session_278259033646055424
[info] Session session_278... sent HELLO (heartbeat_interval: 45000ms)
[debug] Session session_278... scheduled first heartbeat check in 45000ms
```

### 2. Client Connection & Identification
```
[info] Client connected to gateway, session_id=session_278259033646055424
[info] Gateway processing IDENTIFY for session session_278..., user_id=user_123, guilds=[]
[info] Session session_278... identified as user_id=user_123
[info] ✓ Session session_278... successfully identified
```

### 3. Heartbeat Flow (Every 45 seconds)
```
[debug] Gateway received opcode 1 (heartbeat) from session session_278...
[debug] Gateway forwarding HEARTBEAT to Session session_278...
[debug] Session session_278... received HEARTBEAT (state: identified, 2345ms since last)
[debug] Session session_278... sent HEARTBEAT_ACK
```

### 4. Heartbeat Check (Server-side validation)
```
[debug] Session session_278... heartbeat check (state: identified, 2456ms since last, timeout: 60000ms)
[debug] Session session_278... heartbeat check OK (2456ms < 60000ms)
```

### 5. Missed Heartbeat → Zombie State
```
[warning] ⚠ Session session_278... missed heartbeat (65000ms > 60000ms), entering ZOMBIE state
```

### 6. Recovery from Zombie
```
[debug] Session session_278... received HEARTBEAT (state: zombie, 70000ms since last)
[info] ✓ Session session_278... recovered from zombie state via heartbeat
[debug] Session session_278... sent HEARTBEAT_ACK
```

### 7. Zombie Cleanup (After 3 minutes)
```
[warning] 💀 Cleaning up zombie session session_278... (180000ms timeout expired)
[info] Session session_278... terminating: normal
```

## Testing Different Scenarios

### Scenario 1: Normal Heartbeat (Healthy Connection)

1. Start server with debug logs
2. Open gateway_test.html
3. Connect and identify
4. Enable auto-heartbeat (default: ON)
5. **Watch logs**: Every 45s you'll see heartbeat → ACK

**Expected Pattern:**
```
T+0s:   IDENTIFY
T+45s:  HEARTBEAT → ACK
T+90s:  HEARTBEAT → ACK
T+135s: HEARTBEAT → ACK
...
```

### Scenario 2: Missed Heartbeat (Zombie State)

1. Start server with debug logs
2. Open gateway_test.html
3. Connect and identify
4. **Disable auto-heartbeat**
5. Wait 60+ seconds
6. **Watch logs**: Session enters zombie state

**Expected Pattern:**
```
T+0s:   IDENTIFY
T+45s:  Heartbeat check (no heartbeat received)
T+60s:  ⚠ Session missed heartbeat, entering ZOMBIE state
```

### Scenario 3: Recovery from Zombie

1. Follow Scenario 2 to enter zombie state
2. Send manual heartbeat (click button)
3. **Watch logs**: Session recovers immediately

**Expected Pattern:**
```
T+70s:  Manual HEARTBEAT sent
T+70s:  ✓ Session recovered from zombie state via heartbeat
```

### Scenario 4: Zombie Cleanup

1. Follow Scenario 2 to enter zombie state
2. Wait 3 minutes without heartbeat
3. **Watch logs**: Session gets cleaned up

**Expected Pattern:**
```
T+60s:  ⚠ Session missed heartbeat, entering ZOMBIE state
T+240s: 💀 Cleaning up zombie session (180000ms timeout expired)
```

## Log Levels Explained

| Level | What It Shows |
|-------|---------------|
| `:debug` | Everything (heartbeat checks, ACKs, timing details) |
| `:info` | Session lifecycle, IDENTIFY, zombie recovery |
| `:warning` | Missed heartbeats, zombie state, cleanup |
| `:error` | Connection failures, auth errors |

## Timing Reference

| Event | Interval |
|-------|----------|
| Heartbeat interval | 45 seconds |
| Heartbeat timeout | 60 seconds |
| Heartbeat check | Every 45 seconds |
| Zombie cleanup | 180 seconds (3 min) |

## Troubleshooting

### "I don't see any heartbeat logs"

**Possible causes:**
1. Debug logging not enabled → Enable with `LOGGER_LEVEL=debug`
2. Client not connected → Check browser console
3. Auto-heartbeat disabled → Check checkbox in UI
4. Phoenix.js not loaded → Check browser console for errors

### "Session immediately becomes zombie"

**Possible causes:**
1. Client not sending heartbeats
2. Network issues causing packet loss
3. Client-side timer not working

**Check:**
```javascript
// In browser console:
console.log(document.getElementById('autoHeartbeat').checked)
```

### "Zombie state but not cleaning up"

This is **expected behavior**. Zombie cleanup happens after 3 minutes to allow clients time to reconnect.

## Real-Time Monitoring Commands

### Count active sessions
```elixir
Registry.count(Banter.SessionRegistry)
```

### List all sessions
```elixir
Registry.select(Banter.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
```

### Get session state
```elixir
Banter.Session.get_state("session_123...")
# Returns: {:ok, %{state: :identified, sequence: 42, ...}}
```

### Monitor heartbeat activity
```bash
# In terminal:
tail -f log/dev.log | grep -i heartbeat
```

## Performance Notes

- Each session uses ~1KB memory
- Heartbeat checks are non-blocking
- Logger calls are async by default
- Debug logs have minimal overhead (~10μs per log)

## Pro Tips

1. **Use grep to filter**: `mix phx.server | grep HEARTBEAT`
2. **Watch specific session**: `tail -f log/dev.log | grep session_123`
3. **Count heartbeats**: `grep "HEARTBEAT_ACK" log/dev.log | wc -l`
4. **Monitor zombie states**: `tail -f log/dev.log | grep -i zombie`
