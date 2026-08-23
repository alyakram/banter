defmodule BanterWeb.UserSocket do
  use Phoenix.Socket

  # Channels
  channel "gateway:*", BanterWeb.GatewayChannel

  # Deliberately loose backstop against raw connection flooding — see
  # AUDIT_FINDINGS.md #5. IDENTIFY/RESUME (the actual named attack vector)
  # get a tighter, dedicated limit in GatewayChannel.
  @connect_limit 60
  @connect_window_ms 60_000

  @impl true
  def connect(_params, socket, connect_info) do
    ip = peer_ip(connect_info)

    case Banter.RateLimiter.check_rate(:gateway_connect, ip, @connect_limit, @connect_window_ms) do
      :ok -> {:ok, assign(socket, :client_ip, ip)}
      {:error, :rate_limited} -> :error
    end
  end

  @impl true
  def id(_socket), do: nil

  defp peer_ip(%{peer_data: %{address: address}}) do
    case :inet.ntoa(address) do
      # :inet.ntoa/1 returns {:error, :einval} (not a raise) for a
      # malformed address — piping that into to_string/1 would raise
      # Protocol.UndefinedError, so it's handled explicitly here instead.
      {:error, _reason} -> "unknown"
      charlist -> to_string(charlist)
    end
  end

  defp peer_ip(_), do: "unknown"
end
