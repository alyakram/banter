# Discord Clone UI — Setup Guide

## 1. Add the routes

Open `lib/banter_web/router.ex` and add these routes inside
your authenticated scope (the one with `require_authenticated_user`):

```elixir
scope "/", BanterWeb do
  pipe_through [:browser, :require_authenticated_user]

  live "/chat", ChatLive, :index
  live "/chat/:server_id", ChatLive, :server
  live "/chat/:server_id/:channel_id", ChatLive, :channel
end
```

## 2. Add the JavaScript hook

In `assets/js/app.js`, import and register the hook:

```javascript
// At the top of app.js, add:
import Hooks from "./hooks"

// Then find the LiveSocket initialization and add hooks:
let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,  // <-- add this
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken}
})
```

## 3. Copy the LiveView file

Copy `lib/banter_web/live/chat_live.ex` into your project.

## 4. Hide the default Phoenix layout

The chat layout is full-screen, so you'll want to hide the default
Phoenix header/nav. The simplest way: create a chat layout.

In `lib/banter_web/components/layouts.ex`, add:

```elixir
def chat(assigns) do
  ~H"""
  <main>
    {@inner_content}
  </main>
  """
end
```

Then in your router, you can use `put_layout` in the pipeline or
set it directly in the LiveView mount:

```elixir
# Option A: In the LiveView mount
def mount(_params, _session, socket) do
  # ... existing code ...
  {:ok, socket, layout: {BanterWeb.Layouts, :chat}}
end
```

Or **Option B** — just override the app layout to be minimal when on `/chat`:

In `lib/banter_web/components/layouts/app.html.heex`,
wrap the existing content so it doesn't show nav on chat pages.

## 5. Add the IBM Plex Sans font

In `lib/banter_web/components/layouts/root.html.heex`,
add inside `<head>`:

```html
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600;700&display=swap" rel="stylesheet">
```

## 6. Test it

1. Start the server: `mix phx.server`
2. Register/login at `http://localhost:4000`
3. Go to `http://localhost:4000/chat`
4. Click the `+` button in the server rail to create a server
5. You should see the full Discord-style layout with your #general channel

## File Structure

```
lib/banter_web/
├── live/
│   └── chat_live.ex           # Main chat interface (NEW)
├── components/
│   └── layouts/
│       └── chat.html.heex     # Minimal layout for chat (optional)
assets/js/
├── app.js                     # Add hooks import
└── hooks.js                   # ScrollToBottom hook (NEW)
```

## Color Palette

The UI uses a deep indigo-navy theme (not Discord's exact colors,
but inspired by them):

| Purpose          | Color     |
|------------------|-----------|
| Background dark  | `#0f0f1a` |
| Server rail      | `#0f0f1a` |
| Sidebar          | `#16162a` |
| Chat area        | `#1e1e38` |
| Input/card       | `#2a2a4a` |
| Accent (blurple) | `#5865f2` |
| Success/online   | `#3ba55c` |
| Text primary     | `#dcddde` |
| Text muted       | `#72767d` |
