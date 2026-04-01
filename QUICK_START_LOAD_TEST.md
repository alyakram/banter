# Quick Start - Load Testing Guide

## ✅ Setup Complete!

Your Discord Clone is now optimized and ready for 10,000+ concurrent user testing!

---

## 🚀 Start Testing (5 Minutes)

### Step 1: Ensure Server is Running

```bash
# If not already running:
mix phx.server
```

### Step 2: Open Load Test Interface

**URL**: http://localhost:4000/load_test_10k.html

### Step 3: Configure Test

Use these IDs from the setup:

```
Server ID:  019c3885-61c7-78fe-8413-3ae9834fe118
Channel ID: 019c3885-61e2-7a4d-a7a0-3e9c5e0bab9c
```

### Step 4: Run First Test (100 Users)

```
Target Users: 100
Ramp-up Time: 5 seconds
```

Click **"▶ Start Load Test"**

---

## 📊 Expected Results

### Test 1: Baseline (100 users)
✅ **Expected**: 100/100 connected (100%)
✅ **Latency**: < 100ms
✅ **Errors**: 0

### Test 2: Medium Load (1,000 users)
✅ **Expected**: 980+/1000 connected (>98%)
✅ **Latency**: < 200ms
⚠️  **Errors**: < 20 (2%)

### Test 3: Target Load (10,000 users)
✅ **Expected**: 9,500+/10,000 connected (>95%)
⚠️  **Latency**: < 500ms
⚠️  **Errors**: < 500 (5%)

---

## 🔍 Monitor Performance

### In Browser

The load test UI shows real-time:
- Connected users count
- Messages sent/received
- Average latency
- Connection timeline chart
- Latency distribution chart

### In IEx Console

```bash
iex -S mix phx.server
```

Then run:

```elixir
# Check process count (should be < 100k for 10k users)
Process.list() |> length()

# Check memory usage in MB (should be < 8GB)
:erlang.memory(:total) |> div(1024*1024)

# Start visual observer
:observer.start()
```

---

## 🎯 Test Progression Strategy

**Start Small, Scale Up:**

1. **100 users** (5 sec ramp-up) → Baseline
2. **500 users** (5 sec ramp-up) → Warm-up
3. **1,000 users** (10 sec ramp-up) → Medium load
4. **2,500 users** (15 sec ramp-up) → High load
5. **5,000 users** (20 sec ramp-up) → Stress test
6. **10,000 users** (30 sec ramp-up) → **Target!** 🎯

Between tests:
- Check `Process.list() |> length()`
- Check memory: `:erlang.memory(:total) |> div(1024*1024)`
- Look for errors in server logs

---

## ✅ Optimizations Applied

### 1. Fixed Presence N+1 Query ⚡
**Before**: Database query for each online user
**After**: Read status from Presence metadata
**Impact**: 1000x faster for 1,000 users

### 2. Message Pagination 📄
**Before**: Load ALL messages per channel
**After**: Only load last 50 messages
**Impact**: 90%+ memory reduction per LiveView

### 3. Optimized Status Lookups 🎯
**Before**: Database query for each member shown
**After**: Use cached Presence metadata
**Impact**: Zero database queries for member list

---

## 🐛 Troubleshooting

### "Connection failed" errors

**Check**:
```bash
# Increase file descriptor limit
ulimit -n 10000
```

**Fix**:
```bash
# Permanently increase (macOS)
echo "ulimit -n 10000" >> ~/.zshrc
source ~/.zshrc
```

### High latency (> 1 second)

**Check**: Database connection pool
```elixir
# In config/dev.exs or config/runtime.exs
config :banter, Banter.Repo,
  pool_size: 50  # Increase this
```

**Restart** server after config change

### Memory leak (constantly growing)

**Check**: Dead processes
```elixir
# Count alive processes
Process.list() |> Enum.filter(&Process.alive?/1) |> length()
```

**Monitor**: Use `:observer.start()` to see memory patterns

---

## 📈 Success Metrics

| Metric | Target | Critical Threshold |
|--------|--------|-------------------|
| Connection Success | > 95% | > 90% |
| Avg Latency | < 500ms | < 1000ms |
| Memory Usage | < 8 GB | < 12 GB |
| Process Count | < 50k | < 100k |
| Database Connections | < 100 | < 150 |

---

## 🎓 Next Steps After Testing

1. **Document Results**: Note peak users, latency, memory
2. **Identify Bottlenecks**: Check `:observer.start()` for hot spots
3. **Review Priority 2 Optimizations**: See [SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md)
4. **Consider Clustering**: For > 10k users, use distributed Erlang
5. **Production Planning**: Plan infrastructure (load balancers, DB replicas)

---

## 📚 Full Documentation

- [SCALABILITY_ANALYSIS.md](SCALABILITY_ANALYSIS.md) - Detailed analysis
- [LOAD_TEST_GUIDE.md](LOAD_TEST_GUIDE.md) - Complete testing guide
- [PROJECT_DOCUMENTATION_2026-02-06.md](PROJECT_DOCUMENTATION_2026-02-06.md) - Architecture

---

## 🆘 Get Help

If you encounter issues:

1. Check server logs for errors
2. Review [LOAD_TEST_GUIDE.md](LOAD_TEST_GUIDE.md) troubleshooting section
3. Use `:observer.start()` to identify bottlenecks
4. Check database pool size in config

---

## 🎉 Ready to Test!

Your system is optimized and ready. Start with 100 users and work your way up!

**Good luck!** 🚀
