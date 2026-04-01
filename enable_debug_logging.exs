# Script to enable debug logging for Session and Gateway
# Run with: iex -S mix
# Then in IEx: Code.eval_file("enable_debug_logging.exs")

require Logger

Logger.configure(level: :debug)

IO.puts("""

✅ Debug logging enabled!

Now you'll see detailed logs for:
- Session lifecycle (start, identify, heartbeat)
- Heartbeat checks every 45 seconds
- Heartbeat ACKs
- Zombie state transitions
- Session cleanup

To see heartbeat logs in action:
1. Start server: mix phx.server
2. Open: http://localhost:4000/gateway_test.html
3. Click "Connect"
4. Wait for HELLO message
5. Enter user_id and click "Send IDENTIFY"
6. Watch terminal for debug logs!

Example logs you'll see:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[info] 🚀 Starting Session for session_id=session_123...
[info] Session session_123... sent HELLO (heartbeat_interval: 45000ms)
[debug] Session session_123... scheduled first heartbeat check in 45000ms
[debug] Gateway received opcode 1 (heartbeat) from session session_123...
[debug] Session session_123... received HEARTBEAT (state: identified, 2345ms since last)
[debug] Session session_123... sent HEARTBEAT_ACK
[debug] Session session_123... heartbeat check (state: identified, 2456ms since last, timeout: 60000ms)
[debug] Session session_123... heartbeat check OK (2456ms < 60000ms)
[warning] ⚠ Session session_123... missed heartbeat (65000ms > 60000ms), entering ZOMBIE state
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

To disable debug logs:
Logger.configure(level: :info)
""")
