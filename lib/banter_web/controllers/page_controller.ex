defmodule BanterWeb.PageController do
  use BanterWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: "/chat")
  end
end
