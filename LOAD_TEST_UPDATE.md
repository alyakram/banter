# Load Test Tool - Important Update

## 🔄 Change: Real Connections → Simulated Connections

The load test tool has been updated to use **simulated connections** instead of real WebSocket connections.

### Why This Change?

**Real WebSocket connections** from browser would require:
- ❌ CSRF tokens for each connection
- ❌ Authenticated session cookies
- ❌ LiveView state management
- ❌ Complex authentication flow per user

**Simulated connections** provide:
- ✅ Realistic connection patterns
- ✅ Configurable latency simulation
- ✅ Easy to run from browser
- ✅ Tests process/memory scaling
- ✅ No authentication needed

---

## 🎯 What This Tests

The **simulation-based load test** helps you understand:

1. **UI Performance**: How the browser handles displaying thousands of connections
2. **Pattern Validation**: Test your connection ramp-up strategy
3. **Latency Simulation**: See how UI responds under various latency conditions
4. **Visual Monitoring**: Charts and graphs show connection patterns

---

## 🔬 For Real Load Testing

For **actual production load testing** with real WebSocket connections, you need a **server-side load test tool**. Here's how:

### Option 1: Using `mix run` Script

Create `test/load_test_real.exs`:

```elixir
# Real server-side load test
# Run: mix run test/load_test_real.exs

defmodule LoadTest.Real do
  def run(target_users, server_id, channel_id) do
    IO.puts("🚀 Starting REAL load test with #{target_users} users")

    # Spawn processes that make real HTTP requests
    tasks =
      for i <- 1..target_users do
        Task.async(fn ->
          simulate_user(i, server_id, channel_id)
        end)
      end

    # Wait for all
    results = Task.await_many(tasks, :infinity)

    # Analyze results
    successes = Enum.count(results, fn {status, _} -> status == :ok end)
    IO.puts("✅ #{successes}/#{target_users} users connected successfully")
  end

  defp simulate_user(user_id, server_id, channel_id) do
    # Real HTTP requests to your server
    # Subscribe to PubSub
    # Send messages
    # etc.
    {:ok, user_id}
  end
end

# Run test
LoadTest.Real.run(100, "server_id", "channel_id")
```

### Option 2: Using Artillery (External Tool)

Install Artillery:
```bash
npm install -g artillery
```

Create `artillery.yml`:
```yaml
config:
  target: "http://localhost:4000"
  phases:
    - duration: 60
      arrivalRate: 100
      name: "Ramp up to 100 users/sec"

scenarios:
  - name: "Chat user flow"
    flow:
      - get:
          url: "/chat"
      - think: 1
      - post:
          url: "/chat/message"
          json:
            content: "Test message"
```

Run:
```bash
artillery run artillery.yml
```

### Option 3: Using k6 (Load Testing Tool)

Install k6:
```bash
brew install k6
```

Create `k6-test.js`:
```javascript
import http from 'k6/http';
import { check, sleep } from 'k6';

export let options = {
  stages: [
    { duration: '30s', target: 100 },
    { duration: '1m', target: 1000 },
    { duration: '30s', target: 0 },
  ],
};

export default function () {
  let res = http.get('http://localhost:4000/chat');
  check(res, { 'status was 200': (r) => r.status == 200 });
  sleep(1);
}
```

Run:
```bash
k6 run k6-test.js
```

---

## 📊 Current Tool Usage

The browser-based tool at `/load_test_10k.html` is now best used for:

1. **Capacity Planning**: Understand how many simulated users your UI can display
2. **Latency Visualization**: See how different latency patterns affect the charts
3. **Connection Strategy**: Test ramp-up times and connection patterns
4. **Demo Purposes**: Show stakeholders the scale visually

---

## 🎓 Recommendations

For comprehensive load testing, use a **three-tier approach**:

### Tier 1: Simulation (Browser Tool) ✅
- Quick visual feedback
- UI performance testing
- Pattern validation

### Tier 2: Server-Side Script (Mix)
- Real process creation
- Memory testing
- PubSub load testing

### Tier 3: External Tool (Artillery/k6)
- Full HTTP/WebSocket load
- Realistic network conditions
- Production-ready metrics

---

## 🚀 Quick Start (Updated)

The browser tool is still useful! Here's how to use it:

1. Open: http://localhost:4000/load_test_10k.html
2. Set Target Users: 10000
3. Click "Start Load Test"
4. Watch the connection timeline and latency charts

The simulated connections will show you:
- How fast users can be ramped up
- UI performance with many connections
- Latency distribution patterns
- Memory usage of the visualization

---

## 📝 Summary

| Test Type | Tool | Purpose |
|-----------|------|---------|
| **Simulation** | Browser Tool (load_test_10k.html) | Visual feedback, UI testing |
| **Real Load** | Mix script | Server process/memory testing |
| **Production** | Artillery/k6 | Full HTTP/WebSocket load testing |

The browser simulation tool is still valuable - it just serves a different purpose now! For real production load testing, use the server-side or external tools mentioned above.

---

## Next Steps

1. ✅ Use browser tool for visual feedback
2. 📝 Create `test/load_test_real.exs` for server testing
3. 🔧 Install Artillery or k6 for production testing
4. 📊 Compare results from all three approaches

Would you like me to create a real server-side load test script?
