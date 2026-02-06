defmodule DiscordCloneWeb.PageController do
  use DiscordCloneWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
