defmodule Banter.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BanterWeb.Telemetry,
      Banter.Repo,
      {DNSCluster, query: Application.get_env(:banter, :dns_cluster_query) || :ignore},
      {Oban,
       AshOban.config(
         Application.fetch_env!(:banter, :ash_domains),
         Application.fetch_env!(:banter, Oban)
       )},
      {Phoenix.PubSub, name: Banter.PubSub},
      # Presence tracking for online users
      BanterWeb.Presence,
      # Snowflake ID generator (removed - using UUID v7 instead)
      # Banter.Snowflake,
      # Registry for guild process discovery
      {Registry, keys: :unique, name: Banter.GuildRegistry},
      # DynamicSupervisor for guild processes
      {DynamicSupervisor, strategy: :one_for_one, name: Banter.GuildSupervisor},
      # Registry for session process discovery
      {Registry, keys: :unique, name: Banter.SessionRegistry},
      # DynamicSupervisor for session processes
      {DynamicSupervisor, strategy: :one_for_one, name: Banter.SessionSupervisor},
      # Registry for voice room process discovery
      {Registry, keys: :unique, name: Banter.VoiceRoomRegistry},
      # DynamicSupervisor for voice room processes (Membrane RTC Engine instances)
      {DynamicSupervisor, strategy: :one_for_one, name: Banter.VoiceRoomSupervisor},
      # Start to serve requests, typically the last entry
      BanterWeb.Endpoint,
      {AshAuthentication.Supervisor, [otp_app: :banter]}
    ]

    # Ensure upload directory exists
    Banter.Storage.ensure_upload_directory()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Banter.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BanterWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
