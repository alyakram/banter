# Real Load Testing Guide

Complete guide for testing **actual** server load, database, WebSocket, and network capacity.

---

## 🎯 Three Load Test Scripts

### 1. Server + Presence Load Test
**File**: `test/load_test_real.exs`
**Tests**: Server processes, Presence, PubSub, Memory, GuildServer

### 2. Database Load Test
**File**: `test/load_test_database.exs`
**Tests**: Database connections, query performance, connection pool

### 3. WebSocket Load Test
**File**: `test/load_test_websocket.exs`
**Tests**: PubSub channel subscriptions (WebSocket requires external tools)

---

## 🚀 Quick Start

### Test 1: Server & Presence (100 users, 60 seconds)

```bash
# Basic test
mix run test/load_test_real.exs --users 100 --duration 60

# With server/channel for message testing
mix run test/load_test_real.exs \
  --users 100 \
  --server_id "019c3885-61c7-78fe-8413-3ae9834fe118" \
  --channel_id "019c3885-61e2-7a4d-a7a0-3e9c5e0bab9c" \
  --duration 60
```

**What it tests**:
- ✅ Phoenix Presence tracking (N users)
- ✅ PubSub subscriptions
- ✅ GuildServer message handling
- ✅ Database writes (messages)
- ✅ Memory usage per user
- ✅ Process count

**Expected output**:
```
📊 LOAD TEST RESULTS
==================================================
✅ Connection Results:
   Success: 98/100 (98.0%)
   Failures: 2

💬 Message Results:
   Total Messages Sent: 1200
   Messages/Second: 20.0

💾 Memory Usage:
   Initial: 150MB
   Final: 350MB
   Peak: 380MB
   Increase: 200MB
   Per User: 2048KB

⚙️  Process Count:
   Initial: 250
   Final: 450
   Peak: 480
   Increase: 200

Overall Rating: 🎉 EXCELLENT
```

---

### Test 2: Database Performance

```bash
# Basic database test (1000 queries)
mix run test/load_test_database.exs --queries 1000

# With writes (requires server/channel)
mix run test/load_test_database.exs \
  --queries 5000 \
  --server_id "019c3885-61c7-78fe-8413-3ae9834fe118" \
  --channel_id "019c3885-61e2-7a4d-a7a0-3e9c5e0bab9c"
```

**What it tests**:
- ✅ Read query performance
- ✅ Write query performance
- ✅ Concurrent query handling
- ✅ Connection pool saturation
- ✅ Query latency

**Expected output**:
```
📊 DATABASE LOAD TEST RESULTS
==================================================
📖 Read Performance:
   Success Rate: 100.0%
   Avg Query Time: 5ms
   Throughput: 200.0 queries/sec

✍️  Write Performance:
   Success Rate: 98.0%
   Avg Write Time: 15ms
   Throughput: 66.67 writes/sec

🔄 Concurrent Performance:
   Success Rate: 95.0%
   Avg Query Time: 25ms
   Throughput: 40.0 queries/sec
```

---

### Test 3: WebSocket Subscriptions

```bash
mix run test/load_test_websocket.exs --connections 1000 --duration 60
```

**What it tests**:
- ✅ PubSub channel subscriptions
- ✅ Message broadcasting
- ⚠️  Limited WebSocket testing (see external tools below)

---

## 📊 Progressive Load Testing Strategy

### Phase 1: Baseline (100 users)
```bash
mix run test/load_test_real.exs --users 100 --duration 30
```
**Goal**: Establish baseline metrics

### Phase 2: Medium Load (500 users)
```bash
mix run test/load_test_real.exs --users 500 --duration 60
```
**Goal**: Find first bottlenecks

### Phase 3: High Load (1,000 users)
```bash
mix run test/load_test_real.exs --users 1000 --duration 120
```
**Goal**: Stress test with full message flow

### Phase 4: Capacity Test (5,000+ users)
```bash
mix run test/load_test_real.exs --users 5000 --duration 300
```
**Goal**: Find breaking point

---

## 🔧 External Tools for Production WebSocket Testing

### Option 1: Artillery (Recommended)

**Install**:
```bash
npm install -g artillery
```

**Create** `artillery-websocket.yml`:
```yaml
config:
  target: "ws://localhost:4000"
  phases:
    - duration: 60
      arrivalRate: 50
      name: "Ramp up to 50 connections/sec"

  websocket:
    url: "/live/websocket"

scenarios:
  - name: "LiveView Connection"
    engine: "ws"
    flow:
      - connect:
          url: "/live/websocket"
      - think: 10
      - send:
          message: '{"event":"phx_join","topic":"lv:chat","payload":{},"ref":"1"}'
      - think: 60
```

**Run**:
```bash
artillery run artillery-websocket.yml
```

---

### Option 2: k6 (Advanced)

**Install**:
```bash
brew install k6
```

**Create** `k6-websocket.js`:
```javascript
import { WebSocket } from 'k6/ws';
import { check } from 'k6';

export let options = {
  stages: [
    { duration: '30s', target: 100 },
    { duration: '1m', target: 500 },
    { duration: '30s', target: 0 },
  ],
};

export default function () {
  const url = 'ws://localhost:4000/live/websocket';

  const ws = new WebSocket(url);

  ws.on('open', () => {
    ws.send(JSON.stringify({
      event: 'phx_join',
      topic: 'lv:chat',
      payload: {},
      ref: '1'
    }));
  });

  ws.on('message', (data) => {
    check(data, { 'message received': (m) => m.length > 0 });
  });

  ws.on('close', () => console.log('disconnected'));
}
```

**Run**:
```bash
k6 run k6-websocket.js
```

---

### Option 3: Thor (Elixir WebSocket Testing)

**Install**:
Add to `mix.exs`:
```elixir
{:thor, "~> 1.0", only: :test}
```

**Create** `test/thor_websocket_test.exs`:
```elixir
defmodule ThorWebSocketTest do
  use ExUnit.Case

  test "10k WebSocket connections" do
    Thor.run(
      "ws://localhost:4000/live/websocket",
      10_000,  # connections
      60,      # duration (seconds)
      fn socket ->
        # Send join message
        Thor.send(socket, Jason.encode!(%{
          event: "phx_join",
          topic: "lv:chat",
          payload: %{},
          ref: "1"
        }))

        # Wait for messages
        :timer.sleep(60_000)
      end
    )
  end
end
```

---

## 🔍 What to Monitor During Tests

### In IEx Console

```elixir
# Start observer for visual monitoring
:observer.start()

# Check process count
Process.list() |> length()

# Memory breakdown
:erlang.memory()

# Check ETS tables
:ets.all() |> Enum.map(&:ets.info/1)

# Check message queue lengths
Process.list()
|> Enum.map(&Process.info(&1, :message_queue_len))
|> Enum.filter(fn {_, len} -> len > 100 end)

# Database pool status
Ecto.Adapters.SQL.query!(Banter.Repo, "SELECT count(*) FROM pg_stat_activity")
```

### System Monitoring

```bash
# CPU and Memory
htop

# Network connections
netstat -an | grep 4000 | wc -l

# Database connections
psql banter_dev -c "SELECT count(*) FROM pg_stat_activity;"

# File descriptors
lsof -p $(pgrep beam.smp) | wc -l
```

---

## 📈 Performance Benchmarks

### Excellent Performance ✅
- **Connection Success**: > 95%
- **Avg Latency**: < 100ms
- **Memory per User**: < 5MB
- **Database Query Time**: < 10ms
- **Messages/Second**: > 100

### Good Performance 👍
- **Connection Success**: > 90%
- **Avg Latency**: < 200ms
- **Memory per User**: < 10MB
- **Database Query Time**: < 25ms
- **Messages/Second**: > 50

### Needs Improvement ⚠️
- **Connection Success**: < 90%
- **Avg Latency**: > 500ms
- **Memory per User**: > 20MB
- **Database Query Time**: > 50ms
- **Messages/Second**: < 30

---

## 🐛 Common Issues & Solutions

### Issue 1: Connection Pool Exhausted

**Symptoms**: `(DBConnection.ConnectionError) connection not available`

**Solution**: Increase pool size in `config/dev.exs`:
```elixir
config :banter, Banter.Repo,
  pool_size: 50  # Increase from 10
```

### Issue 2: Too Many File Descriptors

**Symptoms**: `{:error, :emfile}`

**Solution**:
```bash
ulimit -n 10000
```

### Issue 3: High Memory Usage

**Symptoms**: Memory grows unbounded

**Solutions**:
1. Check for process leaks: `:observer.start()`
2. Verify pagination is working
3. Look for uncleaned ETS tables

### Issue 4: Slow Database Queries

**Symptoms**: Query times > 100ms

**Solutions**:
1. Add database indexes
2. Optimize Ash queries
3. Enable query logging
4. Use `EXPLAIN ANALYZE`

---

## 🎯 Testing Checklist

Before declaring success, verify:

- [ ] 1,000 concurrent users with >95% success
- [ ] Average latency < 200ms
- [ ] Memory per user < 10MB
- [ ] Database queries < 20ms
- [ ] No memory leaks (stable after 1 hour)
- [ ] Process count stable
- [ ] No database connection errors
- [ ] PubSub broadcasts work
- [ ] GuildServer handles messages correctly

---

## 📝 Next Steps

1. **Run baseline test** (100 users)
2. **Monitor with :observer**
3. **Identify bottlenecks**
4. **Apply optimizations** from SCALABILITY_ANALYSIS.md
5. **Scale up to 1,000 users**
6. **Test for 1 hour** (stability test)
7. **Try 5,000+ users** (find breaking point)

---

## 🚀 Production Deployment Considerations

For production at scale, consider:

1. **Multiple Nodes**: Distributed Erlang cluster
2. **Load Balancer**: nginx/HAProxy with sticky sessions
3. **Database**: Read replicas + connection pooling (PgBouncer)
4. **Monitoring**: Prometheus + Grafana
5. **Rate Limiting**: Protect against abuse
6. **CDN**: Offload static assets
7. **Auto-scaling**: Based on CPU/memory metrics

---

## 📚 Additional Resources

- [Phoenix Presence Docs](https://hexdocs.pm/phoenix/presence.html)
- [Ecto Performance Guide](https://hexdocs.pm/ecto/Ecto.html#module-performance)
- [BEAM VM Tuning](https://www.erlang.org/doc/efficiency_guide/advanced.html)
- [Artillery Documentation](https://artillery.io/docs/)
- [k6 Documentation](https://k6.io/docs/)
