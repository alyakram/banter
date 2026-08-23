defmodule BanterWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a channel connection.

  Such tests rely on `Phoenix.ChannelTest` and also
  import other functionality to make it easier
  to build common data structures.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox in shared mode, so changes done to the database
  are reverted at the end of every test and other processes (e.g. the
  Session/GuildServer GenServers spawned during a test) can see the same
  sandboxed connection.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint BanterWeb.Endpoint

      import Phoenix.ChannelTest
      import BanterWeb.ChannelCase
    end
  end

  setup tags do
    Banter.DataCase.setup_sandbox(tags)
    :ok
  end
end
