defmodule DiscordClone.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DiscordCloneWeb.Telemetry,
      DiscordClone.Repo,
      {DNSCluster, query: Application.get_env(:discord_clone, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DiscordClone.PubSub},
      # Start a worker by calling: DiscordClone.Worker.start_link(arg)
      # {DiscordClone.Worker, arg},
      # Start to serve requests, typically the last entry
      DiscordCloneWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DiscordClone.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DiscordCloneWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
