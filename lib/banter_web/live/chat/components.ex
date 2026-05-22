defmodule BanterWeb.ChatLive.Components do
  @moduledoc """
  Reusable UI components for the Banter chat interface.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Server rail component - left sidebar with server icons.
  """
  attr :servers, :list, required: true
  attr :current_server, :map, default: nil

  def server_rail(assigns) do
    ~H"""
    <nav class="w-[72px] bg-base-300 hidden lg:flex flex-col items-center py-3 gap-2 flex-shrink-0 overflow-y-auto scrollbar-hide">
      <%!-- Home / DMs button --%>
      <button class="w-12 h-12 rounded-2xl bg-primary hover:rounded-xl transition-all duration-200 flex items-center justify-center group">
        <svg class="w-6 h-6 text-white" fill="currentColor" viewBox="0 0 24 24">
          <path d="M19.73 4.87l-15.46 8.73a.5.5 0 0 0 .01.88l4.09 1.72a1 1 0 0 0 .93-.07l8.8-5.76c.1-.06.21.07.12.15l-7.15 6.77a1 1 0 0 0-.3.7l-.2 4.36a.5.5 0 0 0 .85.37l2.39-2.63a.75.75 0 0 1 .87-.17l4.26 1.85a1 1 0 0 0 1.39-.75l2.78-14.94a.5.5 0 0 0-.68-.56z" />
        </svg>
      </button>

      <div class="w-8 h-0.5 bg-neutral rounded-full my-1"></div>

      <%!-- Server icons --%>
      <%= for server <- @servers do %>
        <.server_icon server={server} current_server={@current_server} />
      <% end %>

      <%!-- Join server button --%>
      <button
        phx-click="toggle_join_server_modal"
        class="w-12 h-12 rounded-3xl bg-neutral hover:rounded-xl hover:bg-primary transition-all duration-200 flex items-center justify-center text-primary hover:text-white"
        title="Join a server"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z" />
        </svg>
      </button>

      <%!-- Add server button --%>
      <button
        phx-click="toggle_create_server_modal"
        class="w-12 h-12 rounded-3xl bg-neutral hover:rounded-xl hover:bg-success transition-all duration-200 flex items-center justify-center text-success hover:text-white"
      >
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
        </svg>
      </button>
    </nav>
    """
  end

  @doc """
  Individual server icon button.
  """
  attr :server, :map, required: true
  attr :current_server, :map, default: nil

  def server_icon(assigns) do
    ~H"""
    <div class="relative flex items-center justify-center w-full">
      <%!-- Active indicator pill (left side) --%>
      <div class={[
        "absolute left-0 w-1 rounded-r-full bg-white transition-all duration-200",
        if(@current_server && @current_server.id == @server.id, do: "h-10", else: "h-0 group-hover:h-5")
      ]} />
      <button
        phx-click="select_server"
        phx-value-id={@server.id}
        class={[
          "w-12 h-12 transition-all duration-200 flex items-center justify-center text-sm font-semibold group",
          if(@current_server && @current_server.id == @server.id,
            do: "rounded-2xl bg-primary text-white ring-2 ring-primary ring-offset-2 ring-offset-base-300",
            else:
              "rounded-3xl bg-neutral text-base-content hover:rounded-2xl hover:bg-primary hover:text-white"
          )
        ]}
        title={@server.name}
      >
        <%= server_initials(@server.name) %>
      </button>
    </div>
    """
  end

  @doc """
  Channel sidebar component - middle panel with channels list and user info.
  """
  attr :servers, :list, default: []
  attr :current_server, :map, default: nil
  attr :channels, :list, default: []
  attr :current_channel, :map, default: nil
  attr :current_user, :map, default: nil
  attr :show_status_menu, :boolean, default: false
  attr :voice_states, :map, default: %{}
  attr :current_voice_channel, :map, default: nil
  attr :voice_muted, :boolean, default: false
  attr :voice_deafened, :boolean, default: false
  attr :show_mobile_sidebar, :boolean, default: false

  def channel_sidebar(assigns) do
    ~H"""
    <aside class={[
      "bg-base-200 flex-col flex-shrink-0",
      "lg:flex lg:relative lg:w-60",
      if(@show_mobile_sidebar,
        do: "flex fixed inset-y-0 left-0 z-40 w-72",
        else: "hidden"
      )
    ]}>
      <%!-- Mobile-only: server picker row (server_rail is hidden on mobile) --%>
      <div class="lg:hidden flex-shrink-0 border-b border-base-300 py-2 px-2">
        <div class="flex items-center gap-1.5 overflow-x-auto scrollbar-hide pb-0.5">
          <%= for server <- @servers do %>
            <button
              phx-click="select_server"
              phx-value-id={server.id}
              class={[
                "w-10 h-10 flex-shrink-0 text-xs font-bold transition-all duration-150",
                if(@current_server && @current_server.id == server.id,
                  do: "rounded-xl bg-primary text-primary-content ring-2 ring-primary ring-offset-1 ring-offset-base-200",
                  else: "rounded-full bg-neutral text-neutral-content hover:rounded-xl hover:bg-primary hover:text-primary-content"
                )
              ]}
              title={server.name}
            >
              <%= server_initials(server.name) %>
            </button>
          <% end %>
          <button
            phx-click="toggle_join_server_modal"
            class="w-10 h-10 flex-shrink-0 rounded-full bg-neutral text-primary hover:rounded-xl hover:bg-primary hover:text-primary-content transition-all duration-150 flex items-center justify-center"
            title="Join a server"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z" />
            </svg>
          </button>
          <button
            phx-click="toggle_create_server_modal"
            class="w-10 h-10 flex-shrink-0 rounded-full bg-neutral text-success hover:rounded-xl hover:bg-success hover:text-white transition-all duration-150 flex items-center justify-center"
            title="Create a server"
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
            </svg>
          </button>
        </div>
      </div>

      <%= if @current_server do %>
        <.server_header server={@current_server} />
        <.channel_list
          channels={@channels}
          current_channel={@current_channel}
          voice_states={@voice_states}
          current_voice_channel={@current_voice_channel}
        />
        <.voice_controls
          current_voice_channel={@current_voice_channel}
          voice_muted={@voice_muted}
          voice_deafened={@voice_deafened}
        />
        <.user_info_bar
          current_user={@current_user}
          show_status_menu={@show_status_menu}
        />
      <% else %>
        <div class="flex-1 flex items-center justify-center text-base-content/50 text-sm px-4 text-center">
          <p>Select or create a server to get started</p>
        </div>
      <% end %>
    </aside>
    """
  end

  @doc """
  Server header with name and invite code.
  """
  attr :server, :map, required: true

  def server_header(assigns) do
    ~H"""
    <div class="h-12 px-4 flex items-center justify-between border-b border-base-300 shadow-sm">
      <h2 class="font-semibold text-white text-[15px] truncate"><%= @server.name %></h2>
      <button
        id="invite-code-btn"
        phx-click={JS.dispatch("phx:copy", detail: %{text: @server.invite_code})}
        title={"Click to copy invite code: #{@server.invite_code}"}
        class="text-[11px] bg-neutral text-base-content/50 hover:text-primary-content hover:bg-primary px-2 py-1 rounded transition-colors cursor-pointer select-none"
      >
        <span id="invite-code-label">
          📋 <%= @server.invite_code %>
        </span>
      </button>
    </div>
    """
  end

  @doc """
  Channel list with create button — splits text and voice channels.
  """
  attr :channels, :list, required: true
  attr :current_channel, :map, default: nil
  attr :voice_states, :map, default: %{}
  attr :current_voice_channel, :map, default: nil

  def channel_list(assigns) do
    text_channels = Enum.filter(assigns.channels, &(&1.type in [:text, :announcement]))
    voice_channels = Enum.filter(assigns.channels, &(&1.type == :voice))
    assigns = assign(assigns, :text_channels, text_channels)
    assigns = assign(assigns, :voice_channels, voice_channels)

    ~H"""
    <div class="flex-1 overflow-y-auto py-3 px-2">
      <%!-- Text Channels Section --%>
      <div class="flex items-center justify-between px-1 mb-1">
        <span class="text-[11px] font-bold uppercase tracking-wide text-base-content/50">
          Text Channels
        </span>
        <button
          phx-click="toggle_create_channel_modal"
          class="text-base-content/50 hover:text-base-content transition-colors"
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
        </button>
      </div>

      <%= for channel <- @text_channels do %>
        <.channel_item channel={channel} current_channel={@current_channel} />
      <% end %>

      <%!-- Voice Channels Section --%>
      <div class="flex items-center justify-between px-1 mb-1 mt-4">
        <span class="text-[11px] font-bold uppercase tracking-wide text-base-content/50">
          Voice Channels
        </span>
        <button
          phx-click="toggle_create_channel_modal"
          class="text-base-content/50 hover:text-base-content transition-colors"
        >
          <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
        </button>
      </div>

      <%= for channel <- @voice_channels do %>
        <.voice_channel_item
          channel={channel}
          current_voice_channel={@current_voice_channel}
          users={Map.get(@voice_states, channel.id, [])}
        />
      <% end %>

      <%= if @voice_channels == [] && @text_channels == [] do %>
        <p class="text-base-content/50 text-xs px-2 py-2">No channels yet</p>
      <% end %>
    </div>
    """
  end

  @doc """
  Individual text channel item button.
  """
  attr :channel, :map, required: true
  attr :current_channel, :map, default: nil

  def channel_item(assigns) do
    ~H"""
    <button
      phx-click="select_channel"
      phx-value-id={@channel.id}
      class={[
        "w-full flex items-center gap-1.5 px-2 py-1.5 rounded text-left text-[15px] mb-0.5 transition-colors",
        if(@current_channel && @current_channel.id == @channel.id,
          do: "bg-neutral text-white",
          else: "text-base-content/50 hover:text-base-content hover:bg-base-100"
        )
      ]}
    >
      <span class="text-lg opacity-60">#</span>
      <span class="truncate"><%= @channel.name %></span>
    </button>
    """
  end

  @doc """
  Voice channel item with connected users list.
  """
  attr :channel, :map, required: true
  attr :current_voice_channel, :map, default: nil
  attr :users, :list, default: []

  def voice_channel_item(assigns) do
    ~H"""
    <div class="mb-0.5">
      <button
        phx-click="join_voice_channel"
        phx-value-id={@channel.id}
        class={[
          "w-full flex items-center gap-1.5 px-2 py-1.5 rounded text-left text-[15px] transition-colors",
          if(@current_voice_channel && @current_voice_channel.id == @channel.id,
            do: "bg-neutral text-white",
            else: "text-base-content/50 hover:text-base-content hover:bg-base-100"
          )
        ]}
      >
        <%!-- Speaker icon --%>
        <svg class="w-5 h-5 opacity-60 flex-shrink-0" fill="currentColor" viewBox="0 0 24 24">
          <path d="M12 3v18l-5-4H3V7h4l5-4zm3.5 5.5a3.5 3.5 0 010 7M19 5a9 9 0 010 14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
        </svg>
        <span class="truncate"><%= @channel.name %></span>
      </button>

      <%!-- Connected users --%>
      <%= if @users != [] do %>
        <div class="ml-7 mt-0.5">
          <%= for voice_state <- @users do %>
            <.voice_channel_user voice_state={voice_state} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  A user connected to a voice channel, shown under the channel.
  """
  attr :voice_state, :map, required: true

  def voice_channel_user(assigns) do
    ~H"""
    <div class="flex items-center gap-2 px-2 py-1 rounded hover:bg-base-100 transition-colors">
      <div class="w-6 h-6 rounded-full bg-primary flex items-center justify-center text-[10px] font-bold text-white flex-shrink-0">
        <%= if @voice_state.user,
          do: String.first(@voice_state.user.email |> to_string()) |> String.upcase(),
          else: "?" %>
      </div>
      <span class="text-sm text-base-content truncate flex-1">
        <%= if @voice_state.user, do: @voice_state.user.email |> to_string() |> String.split("@") |> List.first(), else: "Unknown" %>
      </span>
      <%!-- Mute/deaf indicators --%>
      <div class="flex items-center gap-1">
        <%= if @voice_state.self_mute do %>
          <svg class="w-3.5 h-3.5 text-error" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 19L5 5m14 0l-2.5 2.5M12 18.5A6.5 6.5 0 015.5 12M12 18.5V22m0-3.5A6.5 6.5 0 0018.5 12M12 14a2 2 0 01-2-2V6a2 2 0 014 0v4" />
          </svg>
        <% end %>
        <%= if @voice_state.self_deaf do %>
          <svg class="w-3.5 h-3.5 text-error" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1V10a1 1 0 011-1h1.586l4.707-4.707a1 1 0 011.707.707v14a1 1 0 01-1.707.707L5.586 15zM17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2" />
          </svg>
        <% end %>
      </div>
    </div>
    """
  end

  @doc """
  Voice connection controls — shown when user is in a voice channel.
  """
  attr :current_voice_channel, :map, default: nil
  attr :voice_muted, :boolean, default: false
  attr :voice_deafened, :boolean, default: false

  def voice_controls(assigns) do
    ~H"""
    <%= if @current_voice_channel do %>
      <div class="bg-base-300 px-3 py-2 border-b border-base-300">
        <div class="flex items-center justify-between mb-1.5">
          <div class="flex-1 min-w-0">
            <p class="text-xs font-semibold text-success">Voice Connected</p>
            <p class="text-[11px] text-base-content/50 truncate"><%= @current_voice_channel.name %></p>
          </div>
          <%!-- Disconnect button --%>
          <button
            phx-click="leave_voice_channel"
            class="text-base-content/50 hover:text-error transition-colors p-1"
            title="Disconnect"
          >
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 8l-4 4m0 0l-4-4m4 4V3m-6 8a6 6 0 1012 0" />
            </svg>
          </button>
        </div>
        <div class="flex items-center gap-2">
          <%!-- Mute toggle --%>
          <button
            phx-click="toggle_voice_mute"
            class={[
              "p-1.5 rounded transition-colors",
              if(@voice_muted, do: "bg-error text-white", else: "bg-neutral text-base-content hover:bg-neutral/80")
            ]}
            title={if @voice_muted, do: "Unmute", else: "Mute"}
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <%= if @voice_muted do %>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 19L5 5m14 0l-2.5 2.5M12 18.5A6.5 6.5 0 015.5 12M12 18.5V22m0-3.5A6.5 6.5 0 0018.5 12M12 14a2 2 0 01-2-2V6a2 2 0 014 0v4" />
              <% else %>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 10v2a7 7 0 01-14 0v-2m7 9v3m-3 0h6m-3-14a3 3 0 00-3 3v4a3 3 0 006 0V8a3 3 0 00-3-3z" />
              <% end %>
            </svg>
          </button>
          <%!-- Deafen toggle --%>
          <button
            phx-click="toggle_voice_deafen"
            class={[
              "p-1.5 rounded transition-colors",
              if(@voice_deafened, do: "bg-error text-white", else: "bg-neutral text-base-content hover:bg-neutral/80")
            ]}
            title={if @voice_deafened, do: "Undeafen", else: "Deafen"}
          >
            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <%= if @voice_deafened do %>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5.586 15H4a1 1 0 01-1-1V10a1 1 0 011-1h1.586l4.707-4.707a1 1 0 011.707.707v14a1 1 0 01-1.707.707L5.586 15zM17 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2" />
              <% else %>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-5.586-3H4a1 1 0 01-1-1V10a1 1 0 011-1h2.414l4.293-4.293a1 1 0 011.707.707v14.172a1 1 0 01-1.707.707L6.414 15z" />
              <% end %>
            </svg>
          </button>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  User info bar at the bottom of channel sidebar.
  """
  attr :current_user, :map, default: nil
  attr :show_status_menu, :boolean, required: true

  def user_info_bar(assigns) do
    ~H"""
    <div class="h-[52px] bg-base-300 px-2 flex items-center gap-2 relative">
      <%!-- Theme toggle --%>
      <button
        id="theme-toggle"
        type="button"
        title="Toggle theme"
        onclick="
          const h = document.documentElement;
          const next = h.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
          h.setAttribute('data-theme', next);
          localStorage.setItem('phx:theme', next);
        "
        class="p-1.5 rounded text-base-content/50 hover:text-base-content hover:bg-base-100 transition-colors flex-shrink-0"
      >
        <%!-- Moon: shown in light mode (click to go dark) --%>
        <svg class="w-4 h-4 dark:hidden" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" />
        </svg>
        <%!-- Sun: shown in dark mode (click to go light) --%>
        <svg class="w-4 h-4 hidden dark:block" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364-6.364l-.707.707M6.343 17.657l-.707.707M17.657 17.657l-.707-.707M6.343 6.343l-.707-.707M12 8a4 4 0 100 8 4 4 0 000-8z" />
        </svg>
      </button>

      <div class="relative">
        <div class="w-8 h-8 rounded-full bg-primary flex items-center justify-center text-xs font-bold text-white">
          <%= if @current_user,
            do: String.first(@current_user.email |> to_string()) |> String.upcase(),
            else: "?" %>
        </div>
        <%= if @current_user do %>
          <% current_status = @current_user.availability || :online %>
          <div class={[
            "absolute -bottom-0.5 -right-0.5 w-3 h-3 border-2 border-base-300 rounded-full",
            status_color(current_status)
          ]}></div>
        <% end %>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm font-medium text-white truncate">
          <%= if @current_user, do: @current_user.email, else: "Guest" %>
        </p>
        <%= if @current_user do %>
          <button
            phx-click="toggle_status_menu"
            class={[
              "text-[11px] capitalize hover:underline text-left",
              case @current_user.availability || :online do
                :online -> "text-success"
                :away -> "text-warning"
                :dnd -> "text-error"
                :invisible -> "text-neutral-content"
                _ -> "text-neutral-content"
              end
            ]}
          >
            <%= @current_user.availability || :online %>
            <span class="ml-1">▼</span>
          </button>
        <% end %>
      </div>

      <%= if @show_status_menu do %>
        <.status_menu />
      <% end %>
    </div>
    """
  end

  @doc """
  Status dropdown menu.
  """
  def status_menu(assigns) do
    ~H"""
    <div
      id="status-menu"
      class="absolute bottom-full left-0 mb-2 w-48 bg-base-300 border border-neutral rounded-lg shadow-xl py-2 z-50"
      phx-click-away="toggle_status_menu"
    >
      <.status_menu_item status="online" label="Online" color="bg-success" />
      <.status_menu_item status="away" label="Away" color="bg-warning" />
      <.status_menu_item status="dnd" label="Do Not Disturb" color="bg-error" />
      <.status_menu_item status="invisible" label="Invisible" color="bg-neutral" />
    </div>
    """
  end

  @doc """
  Individual status menu item.
  """
  attr :status, :string, required: true
  attr :label, :string, required: true
  attr :color, :string, required: true

  def status_menu_item(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="change_status"
      phx-value-status={@status}
      class="w-full px-3 py-2 text-left hover:bg-neutral transition-colors flex items-center gap-3"
    >
      <div class={"w-3 h-3 rounded-full #{@color}"}></div>
      <span class="text-sm text-white"><%= @label %></span>
    </button>
    """
  end

  @doc """
  Main chat area with messages and input.
  """
  attr :current_channel, :map, default: nil
  attr :messages, :list, default: []
  attr :message_input, :string, default: ""
  attr :online_users, :list, default: []
  attr :uploads, :map, required: true
  attr :has_more_messages, :boolean, default: false
  attr :loading_more_messages, :boolean, default: false
  attr :current_user, :map, default: nil
  attr :editing_message_id, :string, default: nil
  attr :editing_content, :string, default: ""
  attr :confirming_delete_id, :string, default: nil
  attr :selected_message_id, :string, default: nil

  def chat_area(assigns) do
    ~H"""
    <main class="flex-1 flex flex-col min-w-0 bg-base-100">
      <%= if @current_channel do %>
        <.channel_header channel={@current_channel} />
        <.message_feed
          messages={@messages}
          channel={@current_channel}
          has_more={@has_more_messages}
          loading_more={@loading_more_messages}
          current_user={@current_user}
          editing_message_id={@editing_message_id}
          editing_content={@editing_content}
          confirming_delete_id={@confirming_delete_id}
          selected_message_id={@selected_message_id}
        />
        <.message_input channel={@current_channel} message_input={@message_input} uploads={@uploads} />
      <% else %>
        <%!-- Mobile hamburger shown in empty state too --%>
        <div class="lg:hidden h-12 px-4 flex items-center border-b border-base-300 flex-shrink-0">
          <button class="text-base-content/50 hover:text-base-content p-1 -ml-1" phx-click="toggle_mobile_sidebar">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          </button>
        </div>
        <div class="flex-1 flex items-center justify-center text-base-content/50">
          <p>Select a channel to start chatting</p>
        </div>
      <% end %>
    </main>
    """
  end

  @doc """
  Channel header with name and topic.
  """
  attr :channel, :map, required: true

  def channel_header(assigns) do
    ~H"""
    <div class="h-12 px-4 flex items-center border-b border-base-300 gap-2 flex-shrink-0">
      <%!-- Hamburger — mobile only --%>
      <button class="lg:hidden flex-shrink-0 text-base-content/50 hover:text-base-content p-1 -ml-1" phx-click="toggle_mobile_sidebar">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />
        </svg>
      </button>
      <span class="text-base-content/50 text-xl">#</span>
      <h3 class="font-semibold text-white text-[15px]"><%= @channel.name %></h3>
      <%= if @channel.topic do %>
        <div class="w-px h-5 bg-neutral mx-2"></div>
        <p class="text-sm text-base-content/50 truncate"><%= @channel.topic %></p>
      <% end %>
    </div>
    """
  end

  @doc """
  Message feed with scrollable message list.
  """
  attr :messages, :list, required: true
  attr :channel, :map, required: true
  attr :has_more, :boolean, default: false
  attr :loading_more, :boolean, default: false
  attr :current_user, :map, default: nil
  attr :editing_message_id, :string, default: nil
  attr :editing_content, :string, default: ""
  attr :confirming_delete_id, :string, default: nil
  attr :selected_message_id, :string, default: nil

  def message_feed(assigns) do
    ~H"""
    <div
      id="message-feed"
      class="flex-1 overflow-y-auto px-4 py-4 space-y-1"
      phx-hook="MessageFeed"
      data-channel-id={@channel.id}
      data-has-more={to_string(@has_more)}
    >
      <%= if @loading_more do %>
        <div class="flex justify-center py-3">
          <div class="w-6 h-6 border-2 border-primary border-t-transparent rounded-full animate-spin"></div>
        </div>
      <% end %>

      <%= if @messages == [] do %>
        <.empty_channel_message channel={@channel} />
      <% else %>
        <%= for {message, i} <- Enum.with_index(@messages) do %>
          <% prev = if i > 0, do: Enum.at(@messages, i - 1) %>
          <% same_author = prev && prev.author_id == message.author_id %>
          <% time_gap = prev && DateTime.diff(message.inserted_at, prev.inserted_at, :minute) > 5 %>
          <% compact = same_author && !time_gap %>

          <%= if !compact do %>
            <.message_full
              message={message}
              show_divider={i > 0}
              current_user={@current_user}
              editing_message_id={@editing_message_id}
              editing_content={@editing_content}
              confirming_delete_id={@confirming_delete_id}
              selected_message_id={@selected_message_id}
            />
          <% else %>
            <.message_compact
              message={message}
              current_user={@current_user}
              editing_message_id={@editing_message_id}
              editing_content={@editing_content}
              confirming_delete_id={@confirming_delete_id}
              selected_message_id={@selected_message_id}
            />
          <% end %>
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc """
  Empty channel message placeholder.
  """
  attr :channel, :map, required: true

  def empty_channel_message(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center h-full text-center">
      <div class="w-16 h-16 rounded-full bg-neutral flex items-center justify-center mb-4">
        <span class="text-3xl">#</span>
      </div>
      <h3 class="text-2xl font-bold text-white mb-2">
        Welcome to #<%= @channel.name %>!
      </h3>
      <p class="text-base-content/50 text-sm">
        This is the start of the #<%= @channel.name %> channel.
      </p>
    </div>
    """
  end

  @doc """
  Full message with avatar and username.
  """
  attr :message, :map, required: true
  attr :show_divider, :boolean, default: false
  attr :current_user, :map, default: nil
  attr :editing_message_id, :string, default: nil
  attr :editing_content, :string, default: ""
  attr :confirming_delete_id, :string, default: nil
  attr :selected_message_id, :string, default: nil

  def message_full(assigns) do
    ~H"""
    <div class={[
      "flex gap-3 hover:bg-base-200/50 px-2 py-1 rounded-lg group items-start",
      if(@show_divider, do: "mt-3")
    ]}>
      <%!-- Avatar --%>
      <div class="w-9 h-9 min-w-[2.25rem] min-h-[2.25rem] rounded-full bg-primary flex-none self-start flex items-center justify-center text-sm font-bold text-white mt-0.5">
        <%= author_initial(@message) %>
      </div>

      <%!-- Content --%>
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline gap-2 mb-0.5">
          <span class="font-semibold text-base-content text-[14px]"><%= author_name(@message) %></span>
          <span class="text-[10px] text-base-content/40"><%= format_timestamp(@message.inserted_at) %></span>
          <%= if @message.edited_at do %>
            <span class="text-[10px] text-base-content/40">(edited)</span>
          <% end %>
        </div>

        <%= if @message.id == @editing_message_id do %>
          <.inline_edit_form message={@message} editing_content={@editing_content} />
        <% else %>
          <div class={message_bubble_class(@message, @current_user)}>
            <%= if @message.content && @message.content != "" do %>
              <p class="text-[15px] leading-relaxed break-words whitespace-pre-wrap"><%= @message.content %></p>
            <% end %>
            <%= if has_attachments?(@message) do %>
              <.message_attachments attachments={@message.attachments} />
            <% end %>
          </div>
          <%= if @message.id == @confirming_delete_id do %>
            <.inline_delete_confirm message={@message} />
          <% end %>
        <% end %>
      </div>

      <%!-- ⋮ action trigger (own messages only) --%>
      <%= if @current_user && @message.author_id == @current_user.id && @message.id != @editing_message_id do %>
        <div class="flex-shrink-0 self-start mt-0.5 relative">
          <button
            phx-click="select_message"
            phx-value-id={@message.id}
            class="w-7 h-7 flex items-center justify-center rounded text-base-content/30 hover:text-base-content hover:bg-base-300 transition-colors opacity-60 md:opacity-0 md:group-hover:opacity-100"
            title="Message options"
          >
            <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
              <circle cx="12" cy="5" r="1.5" /><circle cx="12" cy="12" r="1.5" /><circle cx="12" cy="19" r="1.5" />
            </svg>
          </button>
          <%= if @message.id == @selected_message_id do %>
            <.message_action_menu message={@message} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Compact message without avatar (for consecutive messages from same author).
  """
  attr :message, :map, required: true
  attr :current_user, :map, default: nil
  attr :editing_message_id, :string, default: nil
  attr :editing_content, :string, default: ""
  attr :confirming_delete_id, :string, default: nil
  attr :selected_message_id, :string, default: nil

  def message_compact(assigns) do
    ~H"""
    <div class="flex gap-3 hover:bg-base-200/50 px-2 py-0.5 rounded-lg group items-start">
      <div class="w-9 flex-shrink-0 flex justify-center pt-1.5">
        <span class="text-[10px] text-base-content/40 opacity-0 group-hover:opacity-100 transition-opacity">
          <%= Calendar.strftime(@message.inserted_at, "%H:%M") %>
        </span>
      </div>

      <%!-- Content --%>
      <div class="flex-1 min-w-0">
        <%!-- Author name: only shown on mobile since desktop relies on the preceding full message --%>
        <span class="md:hidden text-[11px] font-semibold text-base-content/70 block mb-0.5">
          <%= author_name(@message) %>
        </span>

        <%= if @message.id == @editing_message_id do %>
          <.inline_edit_form message={@message} editing_content={@editing_content} />
        <% else %>
          <div class={message_bubble_class(@message, @current_user)}>
            <%= if @message.content && @message.content != "" do %>
              <p class="text-[15px] leading-relaxed break-words whitespace-pre-wrap"><%= @message.content %></p>
            <% end %>
            <%= if has_attachments?(@message) do %>
              <.message_attachments attachments={@message.attachments} />
            <% end %>
          </div>
          <%= if @message.id == @confirming_delete_id do %>
            <.inline_delete_confirm message={@message} />
          <% end %>
        <% end %>
      </div>

      <%!-- ⋮ action trigger (own messages only) --%>
      <%= if @current_user && @message.author_id == @current_user.id && @message.id != @editing_message_id do %>
        <div class="flex-shrink-0 self-start relative">
          <button
            phx-click="select_message"
            phx-value-id={@message.id}
            class="w-7 h-7 flex items-center justify-center rounded text-base-content/30 hover:text-base-content hover:bg-base-300 transition-colors opacity-60 md:opacity-0 md:group-hover:opacity-100"
            title="Message options"
          >
            <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
              <circle cx="12" cy="5" r="1.5" /><circle cx="12" cy="12" r="1.5" /><circle cx="12" cy="19" r="1.5" />
            </svg>
          </button>
          <%= if @message.id == @selected_message_id do %>
            <.message_action_menu message={@message} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Message input form.
  """
  attr :channel, :map, required: true
  attr :message_input, :string, required: true
  attr :uploads, :map, required: true

  def message_input(assigns) do
    ~H"""
    <div class="px-4 pb-6 flex-shrink-0">
      <%!-- File upload preview area --%>
      <%= if @uploads.attachments.entries != [] do %>
        <div class="mb-2 bg-neutral rounded-lg p-3">
          <div class="flex items-center justify-between mb-2">
            <span class="text-xs font-semibold text-base-content">
              Attachments (<%= length(@uploads.attachments.entries) %>)
            </span>
          </div>
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2">
            <%= for entry <- @uploads.attachments.entries do %>
              <.attachment_preview upload={@uploads.attachments} entry={entry} />
            <% end %>
          </div>
        </div>
      <% end %>

      <.form for={%{}} phx-submit="send_message" phx-change="validate_message" class="bg-neutral rounded-lg flex items-center px-4">
        <%!-- File upload button --%>
        <button
          type="button"
          onclick={"document.getElementById('#{@uploads.attachments.ref}').click()"}
          class="cursor-pointer text-base-content/50 hover:text-base-content transition-colors mr-3"
        >
          <svg class="w-6 h-6" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
        </button>
        <.live_file_input upload={@uploads.attachments} class="hidden" id={@uploads.attachments.ref} />

        <input
          type="text"
          name="content"
          value={@message_input}
          phx-change="update_message_input"
          placeholder={"Message ##{@channel.name}"}
          autocomplete="off"
          class="flex-1 bg-transparent border-none outline-none py-3 text-[15px] text-base-content placeholder-base-content/50 focus:ring-0"
        />
        <button type="submit" class="text-base-content/50 hover:text-base-content transition-colors ml-2">
          <svg class="w-5 h-5 rotate-90" fill="currentColor" viewBox="0 0 24 24">
            <path d="M2.01 21L23 12 2.01 3 2 10l15 2-15 2z" />
          </svg>
        </button>
      </.form>

      <%!-- Upload errors --%>
      <%= for err <- upload_errors(@uploads.attachments) do %>
        <div class="mt-2 text-xs text-red-400">
          <%= error_to_string(err) %>
        </div>
      <% end %>
    </div>
    """
  end

  @doc """
  Members sidebar - right panel showing server members.
  """
  attr :current_server, :map, default: nil
  attr :members, :list, default: []
  attr :online_users, :list, default: []

  def members_sidebar(assigns) do
    ~H"""
    <%= if @current_server do %>
      <aside class="w-60 bg-base-200 flex-shrink-0 overflow-y-auto py-4 px-3 hidden lg:block">
        <h4 class="text-[11px] font-bold uppercase tracking-wide text-base-content/50 px-2 mb-2">
          Members — <%= length(@members) %>
        </h4>
        <%= for member <- @members do %>
          <.member_item member={member} online_users={@online_users} />
        <% end %>
      </aside>
    <% end %>
    """
  end

  @doc """
  Individual member item.
  """
  attr :member, :map, required: true
  attr :online_users, :list, required: true

  def member_item(assigns) do
    assigns = assign(assigns, :status, user_status(assigns.member.user_id, assigns.online_users))

    ~H"""
    <div class="flex items-center gap-3 px-2 py-1.5 rounded hover:bg-base-100 transition-colors cursor-pointer">
      <div class="relative">
        <div class="w-8 h-8 rounded-full bg-primary flex items-center justify-center text-xs font-bold text-white">
          <%= if @member.user,
            do: String.first(@member.user.email |> to_string()) |> String.upcase(),
            else: "?" %>
        </div>
        <div class={[
          "absolute -bottom-0.5 -right-0.5 w-3.5 h-3.5 border-2 border-base-200 rounded-full",
          status_color(@status)
        ]}></div>
      </div>
      <div class="flex-1 min-w-0">
        <p class="text-sm text-base-content truncate">
          <%= @member.nickname || (@member.user && @member.user.email) || "Unknown" %>
        </p>
        <p class="text-[11px] text-base-content/50 capitalize"><%= @member.role %></p>
      </div>
    </div>
    """
  end

  @doc """
  Modal for creating a new server.
  """
  attr :show, :boolean, required: true
  attr :new_server_name, :string, default: ""

  def create_server_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-50">
        <div
          class="bg-base-200 rounded-xl w-full max-w-md p-6 shadow-2xl"
          phx-click-away="toggle_create_server_modal"
        >
          <h2 class="text-2xl font-bold text-white text-center mb-2">Create a server</h2>
          <p class="text-base-content/50 text-center text-sm mb-6">
            Give your new server a personality with a name.
          </p>
          <form phx-submit="create_server">
            <label class="block text-[11px] font-bold uppercase tracking-wide text-base-content/50 mb-2">
              Server Name
            </label>
            <input
              type="text"
              name="name"
              value={@new_server_name}
              placeholder="My Awesome Server"
              required
              autofocus
              class="w-full bg-base-300 border border-neutral rounded-md px-3 py-2.5 text-base-content placeholder-base-content/50 focus:border-primary focus:ring-1 focus:ring-primary outline-none text-sm"
            />
            <div class="flex justify-end gap-3 mt-6">
              <button
                type="button"
                phx-click="toggle_create_server_modal"
                class="px-4 py-2 text-sm text-base-content hover:underline"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="px-6 py-2 bg-primary hover:bg-secondary text-white text-sm font-medium rounded-md transition-colors"
              >
                Create
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Modal for creating a new channel.
  """
  attr :show, :boolean, required: true
  attr :server_name, :string, default: nil
  attr :new_channel_name, :string, default: ""

  def create_channel_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-50">
        <div
          class="bg-base-200 rounded-xl w-full max-w-md p-6 shadow-2xl"
          phx-click-away="toggle_create_channel_modal"
        >
          <h2 class="text-xl font-bold text-white mb-1">Create Channel</h2>
          <p class="text-base-content/50 text-sm mb-5">in <%= @server_name %></p>
          <form phx-submit="create_channel">
            <%!-- Channel Type Selection --%>
            <label class="block text-[11px] font-bold uppercase tracking-wide text-base-content/50 mb-2">
              Channel Type
            </label>
            <div class="flex gap-3 mb-4">
              <label class="flex-1 flex items-center gap-2 bg-base-300 border border-neutral rounded-md px-3 py-2.5 cursor-pointer hover:border-primary transition-colors has-[:checked]:border-primary has-[:checked]:bg-primary/10">
                <input type="radio" name="type" value="text" checked class="text-primary focus:ring-primary bg-base-300 border-neutral" />
                <span class="text-lg opacity-60">#</span>
                <span class="text-sm text-base-content">Text</span>
              </label>
              <label class="flex-1 flex items-center gap-2 bg-base-300 border border-neutral rounded-md px-3 py-2.5 cursor-pointer hover:border-primary transition-colors has-[:checked]:border-primary has-[:checked]:bg-primary/10">
                <input type="radio" name="type" value="voice" class="text-primary focus:ring-primary bg-base-300 border-neutral" />
                <svg class="w-5 h-5 opacity-60" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15.536 8.464a5 5 0 010 7.072M12 6v12m-5.586-3H4a1 1 0 01-1-1V10a1 1 0 011-1h2.414l4.293-4.293a1 1 0 011.707.707v14.172a1 1 0 01-1.707.707L6.414 15z" />
                </svg>
                <span class="text-sm text-base-content">Voice</span>
              </label>
            </div>

            <label class="block text-[11px] font-bold uppercase tracking-wide text-base-content/50 mb-2">
              Channel Name
            </label>
            <div class="flex items-center bg-base-300 border border-neutral rounded-md px-3">
              <span class="text-base-content/50 text-lg mr-1">#</span>
              <input
                type="text"
                name="name"
                value={@new_channel_name}
                placeholder="new-channel"
                required
                autofocus
                class="flex-1 bg-transparent border-none py-2.5 text-base-content placeholder-base-content/50 focus:ring-0 outline-none text-sm"
              />
            </div>
            <div class="flex justify-end gap-3 mt-6">
              <button
                type="button"
                phx-click="toggle_create_channel_modal"
                class="px-4 py-2 text-sm text-base-content hover:underline"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="px-6 py-2 bg-primary hover:bg-secondary text-white text-sm font-medium rounded-md transition-colors"
              >
                Create Channel
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Modal for joining a server by invite code.
  """
  attr :show, :boolean, required: true
  attr :invite_code_input, :string, default: ""

  def join_server_modal(assigns) do
    ~H"""
    <%= if @show do %>
      <div class="fixed inset-0 bg-black/70 flex items-center justify-center z-50">
        <div
          class="bg-base-200 rounded-xl w-full max-w-md p-6 shadow-2xl"
          phx-click-away="toggle_join_server_modal"
        >
          <h2 class="text-2xl font-bold text-white text-center mb-2">Join a server</h2>
          <p class="text-base-content/50 text-center text-sm mb-6">
            Enter an invite code to join an existing server.
          </p>
          <form phx-submit="join_server_by_invite">
            <label class="block text-[11px] font-bold uppercase tracking-wide text-base-content/50 mb-2">
              Invite Code
            </label>
            <input
              type="text"
              name="invite_code"
              value={@invite_code_input}
              placeholder="e.g. I_JPVW"
              required
              autofocus
              class="w-full bg-base-300 border border-neutral rounded-md px-3 py-2.5 text-base-content placeholder-base-content/50 focus:border-primary focus:ring-1 focus:ring-primary outline-none text-sm tracking-widest text-center text-lg"
            />
            <div class="flex justify-end gap-3 mt-6">
              <button
                type="button"
                phx-click="toggle_join_server_modal"
                class="px-4 py-2 text-sm text-base-content hover:underline"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="px-6 py-2 bg-primary hover:bg-secondary text-white text-sm font-medium rounded-md transition-colors"
              >
                Join Server
              </button>
            </div>
          </form>
        </div>
      </div>
    <% end %>
    """
  end

  @doc """
  Attachment preview component for upload area.
  """
  attr :upload, :map, required: true
  attr :entry, :map, required: true

  def attachment_preview(assigns) do
    ~H"""
    <div class="relative bg-base-100 rounded-lg overflow-hidden group">
      <%= if String.starts_with?(@entry.client_type, "image/") do %>
        <.live_img_preview entry={@entry} class="w-full h-24 object-cover" />
      <% else %>
        <div class="h-24 flex items-center justify-center">
          <svg class="w-8 h-8 text-base-content/50" fill="currentColor" viewBox="0 0 24 24">
            <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8l-6-6z" />
            <path d="M14 2v6h6M12 18v-6M9 15l3 3 3-3" />
          </svg>
        </div>
      <% end %>

      <button
        type="button"
        phx-click="cancel_upload"
        phx-value-ref={@entry.ref}
        class="absolute top-1 right-1 bg-red-500 hover:bg-red-600 text-white rounded-full w-5 h-5 flex items-center justify-center opacity-0 group-hover:opacity-100 transition-opacity text-xs font-bold"
      >
        ×
      </button>

      <div class="absolute bottom-0 left-0 right-0 bg-black/60 text-white text-xs p-1 truncate">
        <%= @entry.client_name %>
      </div>

      <%!-- Progress bar --%>
      <div
        class="absolute bottom-0 left-0 h-1 bg-primary transition-all"
        style={"width: #{@entry.progress}%"}
      >
      </div>
    </div>
    """
  end

  @doc """
  Message attachments display component.
  """
  attr :attachments, :list, required: true

  def message_attachments(assigns) do
    ~H"""
    <div class="mt-2 grid grid-cols-1 sm:grid-cols-2 gap-2 max-w-lg">
      <%= for attachment <- @attachments do %>
        <.attachment_display attachment={attachment} />
      <% end %>
    </div>
    """
  end

  @doc """
  Individual attachment display component.
  """
  attr :attachment, :map, required: true

  def attachment_display(assigns) do
    ~H"""
    <a
      href={@attachment.url}
      target="_blank"
      class="block bg-neutral rounded-lg overflow-hidden hover:bg-neutral/80 transition-colors"
    >
      <%= if is_image?(@attachment.content_type) do %>
        <img
          src={@attachment.url}
          alt={@attachment.filename}
          class="w-full max-h-64 object-cover"
          loading="lazy"
        />
        <div class="p-2 text-xs text-base-content/50 flex items-center justify-between">
          <span class="truncate"><%= @attachment.filename %></span>
          <span><%= format_file_size(@attachment.size) %></span>
        </div>
      <% else %>
        <div class="p-4 flex items-center gap-3">
          <div class="w-12 h-12 bg-primary rounded flex items-center justify-center flex-shrink-0">
            <svg class="w-6 h-6 text-white" fill="currentColor" viewBox="0 0 24 24">
              <path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8l-6-6z" />
            </svg>
          </div>
          <div class="flex-1 min-w-0">
            <p class="text-sm text-base-content truncate"><%= @attachment.filename %></p>
            <p class="text-xs text-base-content/50"><%= format_file_size(@attachment.size) %></p>
          </div>
        </div>
      <% end %>
    </a>
    """
  end

  attr :message, :map, required: true

  defp message_action_menu(assigns) do
    ~H"""
    <div
      id={"msg-menu-#{@message.id}"}
      class="absolute right-0 top-full mt-1 w-32 bg-base-300 border border-neutral rounded-xl shadow-xl z-20 py-1 overflow-hidden"
      phx-click-away="deselect_message"
    >
      <button
        phx-click="start_edit"
        phx-value-id={@message.id}
        class="w-full flex items-center gap-2 px-3 py-2 text-sm text-base-content hover:bg-neutral transition-colors text-left"
      >
        <svg class="w-3.5 h-3.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z" />
        </svg>
        Edit
      </button>
      <button
        phx-click="confirm_delete"
        phx-value-id={@message.id}
        class="w-full flex items-center gap-2 px-3 py-2 text-sm text-error hover:bg-neutral transition-colors text-left"
      >
        <svg class="w-3.5 h-3.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16" />
        </svg>
        Delete
      </button>
    </div>
    """
  end

  attr :message, :map, required: true
  attr :editing_content, :string, required: true

  defp inline_edit_form(assigns) do
    ~H"""
    <form phx-submit="save_edit" phx-change="update_edit" class="mt-1">
      <input type="hidden" name="message_id" value={@message.id} />
      <textarea
        name="content"
        rows="3"
        class="w-full bg-base-300 border border-neutral rounded px-3 py-2 text-[15px] text-base-content placeholder-base-content/50 focus:border-primary focus:ring-1 focus:ring-primary outline-none resize-none"
      ><%= @editing_content %></textarea>
      <div class="flex items-center gap-2 mt-1">
        <button
          type="submit"
          class="px-3 py-1 bg-primary hover:bg-secondary text-white text-xs font-medium rounded transition-colors"
        >
          Save
        </button>
        <button
          type="button"
          phx-click="cancel_edit"
          class="px-3 py-1 text-xs text-base-content/60 hover:text-base-content transition-colors"
        >
          Cancel
        </button>
      </div>
    </form>
    """
  end

  attr :message, :map, required: true

  defp inline_delete_confirm(assigns) do
    ~H"""
    <div class="flex items-center gap-2 mt-1 py-1 px-2 bg-error/10 border border-error/30 rounded">
      <span class="text-xs text-error flex-1">Delete this message?</span>
      <button
        phx-click="delete_message"
        phx-value-id={@message.id}
        class="px-2 py-0.5 bg-error hover:bg-error/80 text-white text-xs font-medium rounded transition-colors"
      >
        Confirm
      </button>
      <button
        phx-click="cancel_delete"
        class="px-2 py-0.5 text-xs text-base-content/60 hover:text-base-content transition-colors"
      >
        Cancel
      </button>
    </div>
    """
  end

  # ── Helper Functions ─────────────────────────────────────────────────────

  defp server_initials(name) do
    name
    |> String.split(~r/\s+/)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp author_name(message) do
    case message do
      %{author: %{email: email}} when not is_nil(email) ->
        email |> to_string() |> String.split("@") |> List.first()

      _ ->
        "Unknown"
    end
  end

  defp author_initial(message) do
    message
    |> author_name()
    |> String.first()
    |> String.upcase()
  end

  defp format_timestamp(datetime) do
    today = Date.utc_today()
    date = DateTime.to_date(datetime)

    cond do
      date == today ->
        "Today at #{Calendar.strftime(datetime, "%I:%M %p")}"

      date == Date.add(today, -1) ->
        "Yesterday at #{Calendar.strftime(datetime, "%I:%M %p")}"

      true ->
        Calendar.strftime(datetime, "%m/%d/%Y %I:%M %p")
    end
  end

  defp user_status(user_id, online_users) do
    # Check if user is online first
    if user_id in online_users do
      # OPTIMIZED: Get status from Presence metadata (no database query!)
      # Presence metadata is kept in sync by ChatLive.handle_event("change_status")
      case BanterWeb.Presence.get_user_presence(user_id) do
        {:ok, %{status: status}} -> status
        _ -> :online
      end
    else
      :offline
    end
  end

  defp status_color(status) do
    case status do
      # Green
      :online -> "bg-success"
      # Yellow
      :away -> "bg-warning"
      # Red
      :dnd -> "bg-error"
      # Gray
      :invisible -> "bg-neutral"
      # Gray
      :offline -> "bg-neutral"
      # Gray fallback
      _ -> "bg-neutral"
    end
  end

  defp is_image?(content_type), do: String.starts_with?(content_type, "image/")

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_file_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_file_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp error_to_string(:too_large), do: "File is too large (max 25MB)"
  defp error_to_string(:too_many_files), do: "Too many files (max 10 images)"
  defp error_to_string(:not_accepted), do: "Only image files are allowed"
  defp error_to_string(_), do: "Upload error"

  defp has_attachments?(%{attachments: attachments}) when is_list(attachments) do
    length(attachments) > 0
  end

  defp has_attachments?(_), do: false

  defp message_bubble_class(message, current_user) do
    is_own = current_user && message.author_id == current_user.id
    base = "w-fit max-w-full rounded-2xl px-3 py-2"
    color = if is_own, do: "bg-primary/20", else: "bg-base-200"
    "#{base} #{color}"
  end
end
