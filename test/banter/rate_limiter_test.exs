defmodule Banter.RateLimiterTest do
  # async: false — the sweep test below calls sweep_stale_entries/1 directly
  # against the shared, process-global ETS table, which would otherwise be
  # able to delete entries belonging to other concurrently-running tests.
  use ExUnit.Case, async: false

  alias Banter.RateLimiter

  # A fresh, random scope per test so parallel async tests never share a
  # bucket and interfere with each other's counts.
  defp scope, do: :"test_scope_#{System.unique_integer([:positive])}"

  test "allows up to the limit, then rejects" do
    s = scope()

    for _ <- 1..3, do: assert(:ok == RateLimiter.check_rate(s, "1.2.3.4", 3, 60_000))

    assert {:error, :rate_limited} == RateLimiter.check_rate(s, "1.2.3.4", 3, 60_000)
  end

  test "resets once the window elapses" do
    s = scope()
    window_ms = 50

    for _ <- 1..2, do: assert(:ok == RateLimiter.check_rate(s, "1.2.3.4", 2, window_ms))
    assert {:error, :rate_limited} == RateLimiter.check_rate(s, "1.2.3.4", 2, window_ms)

    Process.sleep(window_ms + 10)

    assert :ok == RateLimiter.check_rate(s, "1.2.3.4", 2, window_ms)
  end

  test "different keys under the same scope don't interfere" do
    s = scope()

    assert :ok == RateLimiter.check_rate(s, "1.1.1.1", 1, 60_000)
    assert {:error, :rate_limited} == RateLimiter.check_rate(s, "1.1.1.1", 1, 60_000)

    # a different key still has its own fresh budget
    assert :ok == RateLimiter.check_rate(s, "2.2.2.2", 1, 60_000)
  end

  test "different scopes for the same key don't interfere" do
    key = "shared-key"

    assert :ok == RateLimiter.check_rate(scope(), key, 1, 60_000)
    assert :ok == RateLimiter.check_rate(scope(), key, 1, 60_000)
  end

  test "sweep removes entries that haven't been touched, and leaves fresh ones" do
    s = scope()

    assert :ok == RateLimiter.check_rate(s, "stale-target", 100, 60_000)
    Process.sleep(100)

    # anything untouched in the last 50ms is "stale" here — the entry
    # above (touched ~100ms ago) qualifies; a fresh one won't. The wide
    # margin (100ms old vs. a 50ms cutoff vs. a fresh, sub-millisecond-old
    # entry) keeps this robust against scheduling jitter on a loaded CI box.
    assert :ok == RateLimiter.check_rate(s, "fresh-target", 100, 60_000)
    removed = RateLimiter.sweep_stale_entries(50)
    assert removed >= 1

    # confirm the stale one was actually deleted, not just counted: a
    # fresh call for the same key starts a brand-new count at 1, so with
    # limit 1 a second call for it is rejected — if the sweep had NOT
    # deleted it, the count would already be 2+ from the check above.
    assert :ok == RateLimiter.check_rate(s, "stale-target", 1, 60_000)
    assert {:error, :rate_limited} == RateLimiter.check_rate(s, "stale-target", 1, 60_000)

    # the fresh entry from just before the sweep should have survived —
    # its count should still be at 1, so a second call trips a limit of 1.
    assert {:error, :rate_limited} == RateLimiter.check_rate(s, "fresh-target", 1, 60_000)
  end

  test "fails open if the ETS table doesn't exist" do
    # Exercises the same rescue clause check_rate/4 uses, but against a
    # table name that genuinely never exists, via check_rate_against/5 —
    # deliberately NOT against the real shared RateLimiter table itself,
    # since deleting/recreating that (even briefly) risks wiping counts for
    # other tests that happen to be scheduled concurrently. limit: 0 makes
    # this meaningful: if the rescue clause didn't fire, a normal call with
    # limit 0 would always return {:error, :rate_limited} (any count is
    # > 0), so this only passes if the fail-open path actually ran.
    result = RateLimiter.check_rate_against(:no_such_rate_limiter_table, scope(), "1.2.3.4", 0, 60_000)
    assert :ok == result
  end
end
