# Online Status Guide

This guide explains how user online status works in the Discord Clone application.

## Overview

The application uses a **hybrid approach** combining:
1. **Phoenix.Presence** - Real-time online/offline tracking
2. **User.availability** - User's preferred status (online, away, dnd, invisible)

## Architecture

### 1. Database Attribute (`availability`)

Each user has an `availability` field with these possible values:
- `:online` - User is active (default)
- `:away` - User is idle
- `:dnd` - Do Not Disturb
- `:invisible` - Appear offline to others

### 2. Phoenix.Presence (Real-time Tracking)

Automatically tracks users when they connect via Gateway WebSocket:
- User connects → Session starts → Presence tracked
- User disconnects → Session ends → Presence untracked
- Works across multiple nodes in distributed systems
- Uses CRDTs for conflict resolution

## How It Works

### When a User Connects:

```elixir
# 1. User opens WebSocket connection to /gateway
# 2. Client sends IDENTIFY with user_id
# 3. Session GenServer handles IDENTIFY:

# In Session.handle_call({:identify, ...})
{:ok, _} = Presence.track(
  channel_pid,
  "users:online",
  user_id,
  %{
    online_at: System.system_time(:second),
    status: user.availability,  # :online, :away, :dnd, :invisible
    session_id: session_id
  }
)
```

### When a User Disconnects:

```elixir
# Session terminates → presence automatically untracked
Presence.untrack(channel_pid, "users:online", user_id)
```

## Usage Examples

### Check if a User is Online

```elixir
# Simple boolean check
BanterWeb.Presence.user_online?("user_123")
# => true or false

# Get full presence info (includes status, session_id, etc.)
{:ok, meta} = BanterWeb.Presence.get_user_presence("user_123")
# => %{online_at: 1234567890, status: :online, session_id: "session_..."}
```

### Get All Online Users

```elixir
# Get just the user IDs
user_ids = BanterWeb.Presence.online_user_ids()
# => ["user_123", "user_456", ...]

# Get full presence list with metadata
all_presence = BanterWeb.Presence.list("users:online")
# => %{
#   "user_123" => %{metas: [%{online_at: 1234567890, status: :online}]},
#   "user_456" => %{metas: [%{online_at: 1234567891, status: :away}]}
# }
```

### Update User's Status

#### Option 1: Update Database (Persistent)

```elixir
# Updates the user's preferred status in database
Accounts.update_user_availability(user_id, %{availability: :away})
```

#### Option 2: Update Presence (Real-time, Session-only)

```elixir
# Updates the status for the current session only
BanterWeb.Presence.update_status(self(), user_id, :dnd)
```

#### Best Practice: Update Both

```elixir
# Update database
Accounts.update_user_availability(user_id, %{availability: :away})

# Update presence for immediate effect
BanterWeb.Presence.update_status(self(), user_id, :away)

# Broadcast status change to all connected clients
Phoenix.PubSub.broadcast(
  Banter.PubSub,
  "users:online",
  {:presence_diff, %{...}}
)
```

### Subscribe to Presence Changes

In a LiveView or Channel:

```elixir
def mount(_params, _session, socket) do
  # Subscribe to presence updates
  Phoenix.PubSub.subscribe(Banter.PubSub, "users:online")

  {:ok, socket}
end

def handle_info(%{event: "presence_diff", payload: diff}, socket) do
  # diff.joins - users who just came online
  # diff.leaves - users who just went offline

  # Update UI accordingly
  {:noreply, assign(socket, online_users: get_online_users())}
end
```

## Integration in LiveView

### Display Online Status Indicator

```elixir
# In your LiveView mount:
def mount(_params, _session, socket) do
  Phoenix.PubSub.subscribe(Banter.PubSub, "users:online")

  socket = assign(socket, :online_users, Presence.online_user_ids())
  {:ok, socket}
end

# Update on presence changes:
def handle_info(%{event: "presence_diff"}, socket) do
  socket = assign(socket, :online_users, Presence.online_user_ids())
  {:noreply, socket}
end
```

### In Template:

```heex
<div class="user-list">
  <%= for user <- @users do %>
    <div class="user">
      <span class={"status-indicator status-#{user_status(user, @online_users)}"}>●</span>
      <%= user.email %>
    </div>
  <% end %>
</div>
```

```elixir
defp user_status(user, online_users) do
  if user.id in online_users do
    case Presence.get_user_presence(user.id) do
      {:ok, %{status: status}} -> status
      _ -> :offline
    end
  else
    :offline
  end
end
```

### CSS for Status Indicators:

```css
.status-indicator {
  display: inline-block;
  width: 10px;
  height: 10px;
  border-radius: 50%;
  margin-right: 5px;
}

.status-online { background-color: #43b581; }    /* Green */
.status-away { background-color: #faa61a; }      /* Yellow */
.status-dnd { background-color: #f04747; }       /* Red */
.status-invisible { background-color: #747f8d; } /* Gray */
.status-offline { background-color: #747f8d; }   /* Gray */
```

## Testing

### Test with Gateway WebSocket

1. Open `http://localhost:4000/gateway_test.html`
2. Click "Connect"
3. Enter user_id and click "Send IDENTIFY"
4. In IEx console, check presence:

```elixir
# Check if user is online
BanterWeb.Presence.user_online?("user_123")

# Get all online users
BanterWeb.Presence.list("users:online")

# Count online users
BanterWeb.Presence.online_user_ids() |> length()
```

### Test Status Updates

```elixir
# Get a user
{:ok, user} = Accounts.get(Banter.Accounts.User, "user_id_here")

# Update their availability
Accounts.update_user_availability(user.id, %{availability: :away})

# Check the change
{:ok, updated_user} = Accounts.get(Banter.Accounts.User, user.id)
updated_user.availability
# => :away
```

## Migration

Run the migration to add the `availability` field:

```bash
mix ecto.migrate
```

This adds:
- `availability` column to `users` table
- Default value: `:online`
- Constraint: must be one of `[:online, :away, :dnd, :invisible]`

## Advanced: Multi-Device Support

Phoenix.Presence supports multiple presences per user (one per device):

```elixir
# Each session tracks separately
# User can be online from phone + desktop = 2 presences

presence_list = Presence.list("users:online")
user_presences = presence_list["user_123"]
# => %{metas: [
#   %{session_id: "session_1", status: :online, online_at: 123},
#   %{session_id: "session_2", status: :online, online_at: 456}
# ]}

# User is considered online if ANY session is active
num_devices = length(user_presences.metas)
```

## Differences: Database vs Presence

| Feature | Database (`availability`) | Presence |
|---------|-------------------------|----------|
| **Persistence** | Permanent | Session-only |
| **Speed** | DB query required | In-memory, instant |
| **Accuracy** | User's preference | Actual connection state |
| **Multi-device** | One value for all | One per session |
| **Best for** | User settings | Real-time online/offline |

## Best Practices

1. **Use Presence for "is online?"** - It's real-time and accurate
2. **Use availability for "what status?"** - Persists across sessions
3. **Subscribe in LiveView** - Get real-time updates automatically
4. **Cache online_users in socket assigns** - Avoid repeated lookups
5. **Update both on status change** - DB for persistence, Presence for real-time

## Troubleshooting

### User shows offline but is connected

Check if presence tracking succeeded:
```elixir
Presence.list("users:online") |> Map.keys()
```

Look for errors in Session logs during IDENTIFY.

### Presence not updating in UI

Ensure you subscribed to PubSub:
```elixir
Phoenix.PubSub.subscribe(Banter.PubSub, "users:online")
```

### User stays online after disconnect

Presence auto-untracks when process dies. Check:
- Is Session process terminating properly?
- Check logs for Session termination messages
- Verify `terminate/2` callback is being called

## API Reference

### Presence Functions

```elixir
# Check if online
Presence.user_online?(user_id) :: boolean()

# Get presence metadata
Presence.get_user_presence(user_id) :: {:ok, map()} | {:error, :not_found}

# Get all online user IDs
Presence.online_user_ids() :: [String.t()]

# Update status (current session only)
Presence.update_status(pid, user_id, status) :: :ok

# Track user (done automatically by Session)
Presence.track(pid, "users:online", user_id, meta) :: {:ok, ref()}

# Untrack user (done automatically on disconnect)
Presence.untrack(pid, "users:online", user_id) :: :ok
```

### Accounts Functions

```elixir
# Update user's availability in database
Accounts.update_user_availability(user_id, %{availability: :away})
```

## Related Files

- [`lib/banter_web/presence.ex`](lib/banter_web/presence.ex) - Presence module
- [`lib/banter/session.ex`](lib/banter/session.ex) - Auto-tracking logic
- [`lib/banter/accounts/user.ex`](lib/banter/accounts/user.ex) - User resource with availability
- [`priv/repo/migrations/*_add_user_availability.exs`](priv/repo/migrations/) - Database migration
