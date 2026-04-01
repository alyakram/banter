defmodule Banter.Snowflake do
  @moduledoc """
  ⚠️  **CURRENTLY UNUSED** - This module is not integrated into the application.
  The codebase uses UUID v7 via Ash Framework's `uuid_v7_primary_key` instead.

  Generates Twitter Snowflake-style IDs for time-ordered unique identifiers.

  ## Format (64 bits total):
  - 42 bits: milliseconds since epoch (2024-01-01 00:00:00 UTC)
  - 10 bits: worker/node ID (0-1023)
  - 12 bits: sequence number (0-4095)

  This allows:
  - ~69 years of timestamps
  - 1024 workers
  - 4096 IDs per millisecond per worker

  ## Why UUID v7 is used instead:
  - Native Postgres UUID type support
  - Built-in Ash Framework integration
  - No GenServer coordination needed
  - Better for Elixir/Phoenix ecosystem

  ## To use Snowflake IDs instead:
  Replace `uuid_v7_primary_key :id` with `attribute :id, :integer, primary?: true`
  in all resources and call `Banter.Snowflake.generate()` in create actions.
  """

  use GenServer
  import Bitwise

  # Epoch: 2024-01-01 00:00:00 UTC
  @epoch 1_704_067_200_000

  # Bit shifts
  @timestamp_shift 22
  @worker_shift 12

  # Masks
  @sequence_mask 0xFFF  # 12 bits = 4095
  @worker_mask 0x3FF    # 10 bits = 1023

  # Client API

  @doc """
  Generates a new Snowflake ID.

  ## Examples

      iex> Banter.Snowflake.generate()
      123456789012345678

  """
  def generate do
    GenServer.call(__MODULE__, :generate)
  end

  @doc """
  Extracts the timestamp from a Snowflake ID.

  Returns milliseconds since the epoch (2024-01-01).

  ## Examples

      iex> id = Banter.Snowflake.generate()
      iex> Banter.Snowflake.timestamp(id)
      1234567

  """
  def timestamp(snowflake) do
    snowflake >>> @timestamp_shift
  end

  @doc """
  Converts a Snowflake timestamp to a DateTime.

  ## Examples

      iex> id = Banter.Snowflake.generate()
      iex> Banter.Snowflake.to_datetime(id)
      ~U[2024-01-15 10:30:45.123Z]

  """
  def to_datetime(snowflake) do
    ms_since_epoch = timestamp(snowflake)
    DateTime.from_unix!(@epoch + ms_since_epoch, :millisecond)
  end

  # Server Callbacks

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    worker_id = Keyword.get(opts, :worker_id, generate_worker_id())

    state = %{
      worker_id: worker_id &&& @worker_mask,
      sequence: 0,
      last_timestamp: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:generate, _from, state) do
    timestamp = current_timestamp()

    {new_timestamp, new_sequence} =
      if timestamp == state.last_timestamp do
        # Same millisecond: increment sequence
        sequence = (state.sequence + 1) &&& @sequence_mask

        if sequence == 0 do
          # Sequence overflow: wait for next millisecond
          {wait_next_millis(timestamp), 0}
        else
          {timestamp, sequence}
        end
      else
        # New millisecond: reset sequence
        {timestamp, 0}
      end

    snowflake =
      (new_timestamp <<< @timestamp_shift) |||
      (state.worker_id <<< @worker_shift) |||
      new_sequence

    new_state = %{
      state |
      sequence: new_sequence,
      last_timestamp: new_timestamp
    }

    {:reply, snowflake, new_state}
  end

  # Private Helpers

  defp current_timestamp do
    System.system_time(:millisecond) - @epoch
  end

  defp wait_next_millis(last_timestamp) do
    timestamp = current_timestamp()

    if timestamp <= last_timestamp do
      Process.sleep(1)
      wait_next_millis(last_timestamp)
    else
      timestamp
    end
  end

  defp generate_worker_id do
    # In production, this would be configured per node
    # For now, use a hash of the node name
    :erlang.phash2(Node.self(), 1024)
  end
end
