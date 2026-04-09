#!/bin/bash
# Launch Claude Code with a named Telegram bot
#
# Usage:
#   bash launch.sh              # launch default bot (no name)
#   bash launch.sh work         # launch bot named "work"
#   bash launch.sh personal     # launch bot named "personal"

BOT_NAME="${1:-}"
[ -n "$BOT_NAME" ] && shift
CUSTOM="$HOME/.claude/plugins/custom/telegram-typing/server.ts"

# Patch plugin files
for target in \
  "$HOME/.claude/plugins/cache/claude-plugins-official/telegram/"*/server.ts \
  "$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"; do
  if [ -f "$target" ]; then
    cp "$CUSTOM" "$target"
  fi
done
echo "Plugin patched."

# Determine state directory
if [ -n "$BOT_NAME" ]; then
  export TELEGRAM_STATE_DIR="$HOME/.claude/channels/telegram-$BOT_NAME"
  if [ ! -f "$TELEGRAM_STATE_DIR/.env" ]; then
    echo "ERROR: Bot '$BOT_NAME' not configured."
    echo "  Run: bash install.sh --add-bot $BOT_NAME YOUR_TOKEN"
    exit 1
  fi
  echo "Launching bot: $BOT_NAME (state: $TELEGRAM_STATE_DIR)"
else
  # Default: use standard directory
  if [ -f "$HOME/.claude/channels/telegram/.env" ]; then
    echo "Launching default bot"
  else
    # Check if any named bots exist
    bots=$(ls -d "$HOME/.claude/channels/telegram-"* 2>/dev/null | while read d; do basename "$d" | sed 's/telegram-//'; done)
    if [ -n "$bots" ]; then
      echo "No default bot configured. Available named bots:"
      echo "$bots" | while read b; do echo "  bash launch.sh $b"; done
      exit 1
    else
      echo "ERROR: No bot configured. Run install.sh first."
      exit 1
    fi
  fi
fi

exec claude --channels plugin:telegram@claude-plugins-official "$@"
