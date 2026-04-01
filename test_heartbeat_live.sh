#!/bin/bash

# Quick test script to verify heartbeat mechanism
# This starts the server with debug logging and shows only heartbeat-related logs

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Discord Clone - Heartbeat Monitor"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Starting server with debug logging..."
echo "Filtering for heartbeat-related events..."
echo ""
echo "Instructions:"
echo "  1. Open http://localhost:4000/gateway_test.html in browser"
echo "  2. Click 'Connect'"
echo "  3. Click 'Send IDENTIFY'"
echo "  4. Watch logs below!"
echo ""
echo "Legend:"
echo "  🚀 = Session start"
echo "  ✓  = Success"
echo "  ⚠  = Warning (zombie state)"
echo "  💀 = Cleanup"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Start server with debug logging and filter for relevant logs
LOGGER_LEVEL=debug mix phx.server 2>&1 | grep -i --line-buffered -E "(Session.*session_|Gateway.*opcode|HEARTBEAT|zombie|IDENTIFY)"
