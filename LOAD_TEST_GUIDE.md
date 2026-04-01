# Load Testing Guide - 10,000 Concurrent Users

## Quick Start

### 1. Start Your Phoenix Server

```bash
mix phx.server
```

Your server should be running on `http://localhost:4000`

### 2. Open the Load Test Tool

Navigate to: `http://localhost:4000/load_test_10k.html`

### 3. Configure Test Parameters

- **Target Users**: Start with 100, then 1000, then 10000
- **Ramp-up Time**: How long to spread out connections (recommend 30s for 10k users)
- **Server ID**: Get from your database (optional - tests presence only if empty)
- **Channel ID**: Get from your database (optional - tests messaging if provided)

### 4. Run Progressive Tests

#### Phase 1: Baseline (100 users)
```
Target Users: 100
Ramp-up Time: 5 seconds
```

**Expected Results**:
- ✅ All 100 users connect successfully
- ✅ 0 errors
- ✅ Messages sent/received smoothly
- ✅ Average latency < 100ms

#### Phase 2: Medium Load (1,000 users)
```
Target Users: 1000
Ramp-up Time: 10 seconds
```

**Expected Results**:
- ✅ 1000 users connect successfully
- ⚠️  May see occasional timeouts (< 1%)
- ✅ Average latency < 200ms
- 📊 Monitor server memory and CPU

#### Phase 3: High Load (5,000 users)
```
Target Users: 5000
Ramp-up Time: 20 seconds
```

**Expected Results**:
- ⚠️  Some connection failures expected (< 5%)
- ⚠️  Average latency may spike (< 500ms)
- 🔍 Look for bottlenecks in logs

#### Phase 4: Target Load (10,000 users)
```
Target Users: 10000
Ramp-up Time: 30 seconds
```

**Expected Results** (with optimizations):
- ✅ Most users connect (> 95%)
- ⚠️  Latency may be high (< 1s)
- 🎯 This is your target!

---

## Monitoring

### Server-Side Metrics

Open IEx console and run:

```elixir
# Check process count
Process.list() |> length()
# Should be < 100,000 for 10k users

# Check memory usage
:erlang.memory(:total) |> div(1024*1024)
# Should be < 8GB for 10k users

# Check ETS table sizes
:ets.info(:user_status_cache)

# Check database pool status
Ecto.Adapters.SQL.query!(Banter.Repo, "SELECT count(*) FROM pg_stat_activity")
```

### Browser-Side Metrics

The load test UI shows real-time:
- **Connected Users**: How many WebSocket connections succeeded
- **Messages Sent**: Total messages pushed to server
- **Messages Received**: Total messages broadcast back
- **Avg Latency**: Round-trip time for messages

### Charts

1. **Connection Timeline**: Shows connection rate over time
2. **Latency Distribution**: Histogram of message latencies

---

## Getting Server/Channel IDs for Testing

### Option 1: Use Test Script

```elixir
# Run in IEx (iex -S mix phx.server)

# Create test server
{:ok, server} = Banter.Chat.create_server(%{
  name: "Load Test Server",
  owner_id: "test_owner_123"
})

# Create test channel
{:ok, channel} = Banter.Chat.create_channel(%{
  name: "load-test",
  server_id: server.id
})

IO.puts("Server ID: #{server.id}")
IO.puts("Channel ID: #{channel.id}")
```

### Option 2: Query Database

```bash
psql banter_dev
```

```sql
-- Get server ID
SELECT id, name FROM servers LIMIT 1;

-- Get channel ID
SELECT id, name, server_id FROM channels LIMIT 1;
```

---

## Troubleshooting

### "Failed to connect" errors

**Symptom**: Many users fail to connect

**Possible Causes**:
1. **Database connection pool exhausted**
   - Check: `mix.exs` - look for `pool_size` in Repo config
   - Fix: Increase pool size to 50-100

2. **File descriptor limit**
   - Check: `ulimit -n` (should be > 10000)
   - Fix: `ulimit -n 100000`

3. **Phoenix endpoint timeout**
   - Check: `config/config.exs` - WebSocket timeout
   - Fix: Increase `timeout: 60_000` in endpoint config

### High latency (> 1 second)

**Possible Causes**:
1. **N+1 database queries** (should be fixed by optimizations)
2. **GuildServer mailbox backup**
   - Check: GenServer message queue length
   - Fix: Use `cast` instead of `call` for messages

3. **PubSub broadcast storm**
   - Check: Number of subscribers per channel
   - Fix: Rate limiting or message batching

### Memory leak

**Symptom**: Memory keeps growing

**Possible Causes**:
1. **Messages accumulating in LiveView state**
   - Fix: Implemented pagination (last 50 messages)

2. **ETS tables growing unbounded**
   - Fix: Add TTL to cache entries

3. **Dead processes not cleaned up**
   - Check: `Process.list() |> Enum.filter(&Process.alive?/1) |> length()`

### Database connection errors

**Symptom**: `Postgrex.Protocol.Error` or timeouts

**Fix**: Increase Postgres `max_connections`:

```bash
# Edit postgresql.conf
max_connections = 200

# Restart Postgres
brew services restart postgresql@14
```

---

## Performance Targets

| Metric | Target | Critical |
|--------|--------|----------|
| Connection success rate | > 95% | > 90% |
| Average latency | < 500ms | < 1000ms |
| Peak memory | < 8 GB | < 12 GB |
| Peak CPU | < 80% | < 95% |
| Database connections | < 100 | < 150 |
| Process count | < 50k | < 100k |

---

## Optimization Checklist

### ✅ Implemented

- [x] Fix Presence N+1 query (read from metadata)
- [x] Message pagination (limit to 50 messages)
- [x] Optimize user_status lookups (use Presence)

### 📋 Recommended Next

- [ ] Add ETS cache for user status
- [ ] Use `GenServer.cast` for async message sends
- [ ] Implement virtual scrolling for member list
- [ ] Add rate limiting (prevent message spam)
- [ ] Batch database queries (preload associations)
- [ ] Tune Ecto pool size (50-100 connections)
- [ ] Increase file descriptor limit (`ulimit -n 100000`)
- [ ] Add message queue monitoring
- [ ] Implement circuit breakers for DB queries

---

## Advanced: Multi-Node Testing

For true 10k+ testing, you'll need multiple Erlang nodes.

### Setup Cluster

**Node 1** (127.0.0.1):
```bash
iex --name node1@127.0.0.1 --cookie secret -S mix phx.server
```

**Node 2** (127.0.0.1):
```bash
PORT=4001 iex --name node2@127.0.0.1 --cookie secret -S mix phx.server
```

**Connect nodes**:
```elixir
# In node1 IEx
Node.connect(:"node2@127.0.0.1")
Node.list()  # Should show [:"node2@127.0.0.1"]
```

Now you can distribute 10k users across both servers!

---

## Results Interpretation

### Good Results ✅
```
Connected: 9800/10000 (98%)
Messages Sent: 50000
Messages Received: 490000 (98% received by all)
Avg Latency: 350ms
Errors: 200 (2%)
```

### Bad Results ❌
```
Connected: 5000/10000 (50%)
Messages Sent: 10000
Messages Received: 10000 (only senders received)
Avg Latency: 5000ms
Errors: 5000 (50%)
```

---

## Next Steps

1. Run baseline test (100 users)
2. Apply optimizations from [SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md)
3. Re-test at 1,000 users
4. Profile bottlenecks with `:observer.start()`
5. Iterate until 10k target achieved

## Resources

- [Phoenix Presence Guide](https://hexdocs.pm/phoenix/presence.html)
- [Erlang Observer](https://www.erlang.org/doc/man/observer.html)
- [BEAM VM Tuning](https://www.erlang.org/doc/efficiency_guide/advanced.html)
- [Postgres Connection Pooling](https://wiki.postgresql.org/wiki/Number_Of_Database_Connections)
