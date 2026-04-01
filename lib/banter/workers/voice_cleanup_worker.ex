defmodule Banter.Workers.VoiceCleanupWorker do
  @moduledoc """
  Periodically sweeps stale voice states from the database.

  A voice state becomes stale when the user has no active Presence entry
  (i.e., all their browser tabs/connections have closed). This handles
  genuine disconnects — tab closed permanently, network loss, browser crash.

  We intentionally do NOT clean up voice states in LiveView's terminate/2
  because page refreshes cause terminate to fire before the new LiveView
  mounts, which would kick the user out of voice on every refresh.

  Runs every 60 seconds via Oban Cron.
  """

  use Oban.Worker, queue: :default

  alias Banter.Chat
  alias BanterWeb.Presence

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    # Get all active voice states from DB
    case Chat.list_all_voice_states() do
      {:ok, all_voice_states} ->
        # Get all tracked user IDs from Presence
        tracked_user_ids =
          Presence.list("users:online")
          |> Map.keys()
          |> MapSet.new()

        # Find voice states with no active presence
        stale = Enum.reject(all_voice_states, &MapSet.member?(tracked_user_ids, &1.user_id))

        if stale != [] do
          Logger.info("VoiceCleanupWorker: cleaning up #{length(stale)} stale voice state(s)")
        end

        # Clean up each stale voice state
        for vs <- stale do
          vs_with_user = Ash.load!(vs, :user)

          case Chat.leave_voice_channel(vs) do
            :ok ->
              Phoenix.PubSub.broadcast(
                Banter.PubSub,
                "guild:#{vs.server_id}",
                {:guild_event,
                 {:voice_state_update, %{action: :leave, voice_state: vs_with_user}}}
              )

            {:error, reason} ->
              Logger.warning(
                "VoiceCleanupWorker: failed to clean up voice state #{vs.id}: #{inspect(reason)}"
              )
          end
        end

        :ok

      {:error, reason} ->
        Logger.error("VoiceCleanupWorker: failed to list voice states: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
