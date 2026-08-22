# Claude.md - AI Assistant Guide

**Project:** Discord Clone
**Framework:** Phoenix LiveView + Ash Framework 3.0
**Language:** Elixir
**Purpose:** Real-time chat application with WebSocket gateway and file uploads

---

## Quick Reference

### Project Overview
A Discord-inspired chat application featuring:
- Real-time messaging with Phoenix PubSub
- **Image file uploads** with local filesystem storage
- User presence tracking with custom statuses (online/away/dnd/invisible)
- WebSocket gateway protocol for external clients
- Guild (server) system with channels and role-based permissions
- Authentication with AshAuthentication + Bcrypt

### Technology Stack
- **Backend:** Phoenix 1.8 + LiveView
- **Data Layer:** Ash Framework 3.0 + PostgreSQL
- **Real-time:** Phoenix PubSub + Phoenix.Presence
- **Auth:** AshAuthentication with JWT tokens
- **Background Jobs:** Oban
- **IDs:** UUID v7 (time-ordered)
- **File Storage:** Local filesystem (priv/static/uploads/)
