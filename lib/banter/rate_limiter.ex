defmodule Banter.RateLimiter do
  use GenServer

  @table __MODULE__
  @sweep_interval_ms :timer.minutes(5)
  @stale_after_ms :timer.minutes(10)

  @moduledoc """
  Fixed-window rate limiter backed by a public ETS table.

  This process only owns the table at boot — every `check_rate/4` call reads
  and writes the table directly from the calling process, so checks never
  serialize through a single GenServer mailbox.

  Each window is its own ETS key (`{scope, key, window_number}`), so
  `:ets.update_counter/4` can atomically initialize-and-increment in one
  call with no read-then-write race between concurrent callers. The
  previous window's bucket for that identity is opportunistically deleted
  on each call, which keeps the table small for callers who return
  regularly — but a caller who's never seen again (a one-time visitor, a
  scanner) leaves an entry that nothing ever revisits to clean up. A
  periodic sweep (every #{div(@sweep_interval_ms, 60_000)} min, dropping
  anything untouched for #{div(@stale_after_ms, 60_000)} min) is the
  backstop for that case, so the table can't grow without bound over a
  long-running node's lifetime.
  """

  # ── Client API ──────────────────────────────────────────────────────

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Records one attempt for `{scope, key}` and returns `:ok` if it's within
  `limit` attempts per `window_ms`, or `{:error, :rate_limited}` otherwise.

  Fails open (`:ok`) if the ETS table doesn't exist — e.g. a brief window
  while the owning process is restarting after a crash. A rate limiter's
  own internal failure shouldn't turn into a bigger outage than whatever
  it's protecting against.
  """
  @spec check_rate(atom, String.t(), pos_integer, pos_integer) ::
          :ok | {:error, :rate_limited}
  def check_rate(scope, key, limit, window_ms) do
    check_rate_against(@table, scope, key, limit, window_ms)
  end

  @doc false
  # Table name is an explicit parameter (rather than hardcoded to @table)
  # specifically so tests can exercise the fail-open rescue clause against
  # a table that genuinely never exists, without touching the real,
  # shared, process-global production table.
  @spec check_rate_against(atom, atom, String.t(), pos_integer, pos_integer) ::
          :ok | {:error, :rate_limited}
  def check_rate_against(table, scope, key, limit, window_ms) do
    now = System.monotonic_time(:millisecond)
    window = div(now, window_ms)
    full_key = {scope, key, window}

    count = :ets.update_counter(table, full_key, {2, 1}, {full_key, 0, now})
    :ets.update_element(table, full_key, {3, now})
    :ets.delete(table, {scope, key, window - 1})

    if count > limit, do: {:error, :rate_limited}, else: :ok
  rescue
    ArgumentError -> :ok
  end

  @doc false
  # Exposed (not `defp`) so tests can trigger a sweep deterministically
  # instead of waiting on the real interval. Returns the number of entries
  # removed.
  @spec sweep_stale_entries(non_neg_integer) :: non_neg_integer
  def sweep_stale_entries(stale_after_ms \\ @stale_after_ms) do
    cutoff = System.monotonic_time(:millisecond) - stale_after_ms
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  # ── Server callbacks ────────────────────────────────────────────────

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_stale_entries()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
