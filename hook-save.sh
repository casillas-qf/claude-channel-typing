#!/bin/bash
# Hook script: saves telegram replies (assistant messages) to SQLite
# Called by Claude Code PostToolUse hook
# Identifies channel instance from TELEGRAM_STATE_DIR env var

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
DB_SCRIPT="$HOME/.claude/channel-history/db.js"

# Determine which channel instance this is
CHANNEL_INSTANCE="telegram"
if [ -n "$TELEGRAM_STATE_DIR" ]; then
  CHANNEL_INSTANCE=$(basename "$TELEGRAM_STATE_DIR")
fi

# Save outgoing replies (assistant messages)
if [ "$TOOL_NAME" = "mcp__plugin_telegram_telegram__reply" ]; then
  CHAT_ID=$(echo "$INPUT" | jq -r '.tool_input.chat_id // empty')
  TEXT=$(echo "$INPUT" | jq -r '.tool_input.text // empty')
  # Extract message_id from tool_response: [{"type":"text","text":"sent (id: 3150)"}]
  TOOL_RESPONSE=$(echo "$INPUT" | jq -r '.tool_response[0].text // empty')
  MSG_ID=$(echo "$TOOL_RESPONSE" | sed -n 's/.*id: \([0-9]*\).*/\1/p')

  if [ -n "$CHAT_ID" ] && [ -n "$TEXT" ]; then
    echo "{
      \"channel\": \"$CHANNEL_INSTANCE\",
      \"chat_id\": \"$CHAT_ID\",
      \"message_id\": $(if [ -n "$MSG_ID" ]; then echo "\"$MSG_ID\""; else echo "null"; fi),
      \"role\": \"assistant\",
      \"content\": $(echo "$TEXT" | jq -Rs .),
      \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",
      \"session_id\": \"${CLAUDE_SESSION_ID:-unknown}\"
    }" | node "$DB_SCRIPT" save > /dev/null 2>&1
  fi
fi

exit 0
