defmodule DiscordClone.Repo do
  use Ecto.Repo,
    otp_app: :discord_clone,
    adapter: Ecto.Adapters.Postgres
end
