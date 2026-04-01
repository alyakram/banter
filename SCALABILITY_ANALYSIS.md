# Scalability Analysis for 10,000 Concurrent Users

## Current Architecture Assessment

### ✅ What's Good

1. **Per-Guild GenServer Pattern** - Excellent for write serialization and fault isolation
2. **Phoenix Presence** - Built-in CRDT-based distributed presence tracking
3. **PubSub Architecture** - Efficient for broadcasting messages
4. **LiveView** - Server-side rendering reduces client load

### ❌ Critical Bottlenecks for 10k Users

#### 1. **Database N+1 Query Problem** (CRITICAL)

**Location**: `lib/banter_web/presence.ex:34-46`

```elixir
def online_user_ids do
  "users:online"
  |> list()
  |> Enum.filter(fn {user_id, _} ->
    # 🔴 DATABASE QUERY FOR EACH USER!
    case Ash.get(Banter.Accounts.User, user_id) do
      {:ok, user} -> user.availability != :invisible
      _ -> true
    end
  end)
  |> Enum.map(fn {user_id, _} -> user_id end)
end
```

**Impact**: If 1000 users are online, this makes 1000+ database queries EVERY time the member list refreshes!

**Solution**: Cache availability in Presence metadata or use ETS for status lookup

---

#### 2. **Synchronous Message Sends** (HIGH)

**Location**: `lib/banter/guild_server.ex:59-63`

```elixir
def send_message(server_id, channel_id, user_id, content) do
  with {:ok, _pid} <- ensure_started(server_id) do
    GenServer.call(via_tuple(server_id), {:send_message, channel_id, user_id, content})
  end
end
```

**Impact**:
- Each message waits for database write + broadcast
- A busy channel becomes a serialization bottleneck
- Under load, GenServer mailbox grows

**Solution**: Use `GenServer.cast` for fire-and-forget, return `:ok` immediately, handle delivery confirmation via PubSub

---

#### 3. **N+1 Member Loading** (HIGH)

**Location**: `lib/banter_web/live/chat/chat_live.ex:371-373`

```elixir
{:ok, members} = Chat.list_server_members(%{server_id: server_id})
members = Ash.load!(members, :user)  # Potentially N+1
```

**Impact**: Loading 100 members could trigger 100+ separate user queries

**Solution**: Ensure Ash preloads are batched or use explicit joins

---

#### 4. **Status Checking in Member Sidebar** (MEDIUM)

**Location**: `lib/banter_web/live/chat/components.ex:570-590`

The `user_status/2` function is called for EVERY member in the sidebar, and it does:
- Database lookup via `Ash.get`
- Fallback to Presence lookup

**Impact**: Rendering a member list of 100 users = 100+ database queries

**Solution**: Batch load user statuses or cache in ETS

---

#### 5. **LiveView Process Memory** (MEDIUM)

Each LiveView process holds:
- Full message list
- Full member list
- Server state
- Channel state

**Impact**: 10,000 LiveView processes × ~10MB each = 100GB+ memory

**Solution**:
- Paginate messages (only show last 50)
- Lazy load members (only render visible ones)
- Use virtual scrolling

---

## Performance Estimates

### Current System (Without Optimizations)

| Metric | Estimate | Reasoning |
|--------|----------|-----------|
| **Max concurrent users** | 500-1000 | Before database query storms |
| **Max users per channel** | 100-200 | Before member list N+1 kills performance |
| **Messages/sec per channel** | 50-100 | Synchronous GenServer.call bottleneck |
| **Memory per user** | 5-10 MB | Full state in LiveView process |
| **Database connections needed** | 50-100 | Ecto pool size × concurrent queries |

### Optimized System (With All Fixes)

| Metric | Estimate | Reasoning |
|--------|----------|-----------|
| **Max concurrent users** | 10,000+ | No N+1, ETS caching |
| **Max users per channel** | 1,000+ | Batched queries, virtual scrolling |
| **Messages/sec per channel** | 1,000+ | Async message handling |
| **Memory per user** | 1-2 MB | Paginated state |
| **Database connections needed** | 20-40 | Batched queries, caching |

---

## Optimization Priority List

### 🔥 Priority 1 (Must Fix for 10k Users)

1. **Fix Presence N+1** - Cache status in Presence metadata or ETS
2. **Batch Member Loading** - Ensure Ash preloads are efficient
3. **Paginate Messages** - Only load last 50 messages per channel
4. **ETS Status Cache** - Cache user status lookups

### 🔶 Priority 2 (Nice to Have)

5. **Async Message Sends** - Use cast instead of call
6. **Virtual Scrolling for Members** - Only render visible members
7. **Database Connection Pooling** - Tune Ecto pool size
8. **Message Rate Limiting** - Prevent spam

### 🔵 Priority 3 (Future Scaling)

9. **Distributed Erlang Cluster** - Horizontal scaling
10. **Redis Caching** - Cache hot data outside application
11. **Message Queue (Oban)** - Offload background work
12. **CDN for Assets** - Reduce server load

---

## Quick Wins (< 1 Hour Implementation)

### 1. Fix Presence N+1

**Before**:
```elixir
def online_user_ids do
  "users:online"
  |> list()
  |> Enum.filter(fn {user_id, _} ->
    case Ash.get(Banter.Accounts.User, user_id) do
      {:ok, user} -> user.availability != :invisible
      _ -> true
    end
  end)
  |> Enum.map(fn {user_id, _} -> user_id end)
end
```

**After**:
```elixir
def online_user_ids do
  "users:online"
  |> list()
  |> Enum.filter(fn {_user_id, %{metas: [meta | _]}} ->
    # Status is already in Presence metadata!
    Map.get(meta, :status, :online) != :invisible
  end)
  |> Enum.map(fn {user_id, _} -> user_id end)
end
```

---

### 2. Paginate Messages

**Configuration**: The `:by_channel` action is already configured with pagination in `lib/banter/chat/message.ex:143-147`:

```elixir
pagination do
  default_limit 50
  max_page_size 100
  keyset? true
end
```

This means every call to `Chat.list_channel_messages` automatically returns only the last 50 messages, drastically reducing memory usage per LiveView process.

---

### 3. Cache User Status in ETS

Create an ETS table for status lookups:

```elixir
defmodule Banter.StatusCache do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def init(_) do
    table = :ets.new(:user_status_cache, [:set, :public, :named_table, read_concurrency: true])
    {:ok, table}
  end

  def get(user_id) do
    case :ets.lookup(:user_status_cache, user_id) do
      [{^user_id, status}] -> status
      [] -> :offline
    end
  end

  def put(user_id, status) do
    :ets.insert(:user_status_cache, {user_id, status})
  end
end
```

---

## Testing Strategy

### Load Test Phases

1. **Phase 1**: 100 users (baseline)
2. **Phase 2**: 1,000 users (find first bottleneck)
3. **Phase 3**: 5,000 users (stress test)
4. **Phase 4**: 10,000 users (target)

### Metrics to Track

- **LiveView process count**: `Process.list() |> length()`
- **Memory usage**: `:erlang.memory(:total)`
- **Message latency**: Time from send to receive
- **Database query time**: Ecto telemetry
- **GenServer mailbox size**: `Process.info(pid, :message_queue_len)`

---

## Hardware Requirements

### Current Machine (Single Node)

For 10,000 concurrent users, you'll need:

- **CPU**: 8+ cores
- **RAM**: 16-32 GB
- **Database**: PostgreSQL with 100+ connection pool
- **Network**: 1 Gbps

### Recommended Production Setup

- **App Servers**: 3-5 nodes (load balanced)
- **Database**: PostgreSQL with read replicas
- **Cache**: Redis cluster
- **Load Balancer**: nginx/HAProxy

---

## Next Steps

1. Run baseline load test (100 users)
2. Implement Priority 1 optimizations
3. Re-test at 1,000 users
4. Implement Priority 2 optimizations
5. Final test at 10,000 users
6. Monitor production metrics

---

## Related Documentation

- [HEARTBEAT_MONITORING.md](HEARTBEAT_MONITORING.md) - Gateway heartbeat implementation
- [ONLINE_STATUS_GUIDE.md](ONLINE_STATUS_GUIDE.md) - Presence tracking guide
- [PROJECT_DOCUMENTATION_2026-02-06.md](PROJECT_DOCUMENTATION_2026-02-06.md) - Architecture overview
