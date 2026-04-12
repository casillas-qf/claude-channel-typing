#!/bin/bash
# ============================================
# Claude Code Bot Runner with Auto-Restart
#
# Usage:
#   ./bot-runner.sh <bot-name>
#
# Runs inside a tmux session named "bot-<name>". Loops forever:
#   1. Patch typing plugin
#   2. Start claude with --continue in a bot-specific workdir
#   3. If claude exits, wait and restart
#
# Uses --continue with per-bot workdir for session isolation.
# Each bot's workdir only has one CC session, so --continue
# always finds the right one. No session-id lock issues.
#
# The bot-name maps to a channel directory:
#   ~/.claude/channels/telegram-<bot-name>/
# ============================================
set -o pipefail

BOT_NAME="${1:?Usage: bot-runner.sh <bot-name>}"
CUSTOM_PLUGIN="$HOME/.claude/plugins/custom/telegram-typing/server.ts"
STATE_DIR="$HOME/.claude/channels/telegram-$BOT_NAME"
BOT_WORKDIR="$HOME/.claude/bot-workdirs/$BOT_NAME"
RESTART_COUNT=0
MAX_RAPID_RESTARTS=10
RAPID_WINDOW=60  # seconds

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Ensure channel directory exists
if [ ! -d "$STATE_DIR" ]; then
  echo -e "${RED}Channel directory not found: $STATE_DIR${NC}"
  echo "Configure the bot first with install.sh"
  exit 1
fi

if [ ! -f "$STATE_DIR/.env" ]; then
  echo -e "${RED}No .env file in $STATE_DIR${NC}"
  exit 1
fi

# Create bot-specific workdir (used for --continue isolation)
mkdir -p "$BOT_WORKDIR"

# Patch typing plugin before each start
patch_plugin() {
  if [ -f "$CUSTOM_PLUGIN" ]; then
    for target in \
      "$HOME/.claude/plugins/cache/claude-plugins-official/telegram/"*/server.ts \
      "$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"; do
      if [ -f "$target" ]; then
        cp "$CUSTOM_PLUGIN" "$target" 2>/dev/null
      fi
    done
    echo -e "${GREEN}[bot-runner] Plugin patched.${NC}"
  fi
}

# Track restart times for rapid-restart detection
declare -a restart_times=()

check_rapid_restart() {
  local now=$(date +%s)
  local new_times=()
  for t in "${restart_times[@]}"; do
    if (( now - t < RAPID_WINDOW )); then
      new_times+=("$t")
    fi
  done
  restart_times=("${new_times[@]}" "$now")

  if (( ${#restart_times[@]} >= MAX_RAPID_RESTARTS )); then
    echo -e "${RED}[bot-runner] Too many rapid restarts ($MAX_RAPID_RESTARTS in ${RAPID_WINDOW}s). Cooling down 5 minutes...${NC}"
    sleep 300
    restart_times=()
  fi
}

# Auto-accept trust prompt by monitoring tmux pane content
auto_accept_trust() {
  local session="bot-$BOT_NAME"
  for i in $(seq 1 15); do
    sleep 1
    local content=$(tmux capture-pane -t "$session" -p 2>/dev/null)
    if echo "$content" | grep -q "Yes, I trust this folder"; then
      tmux send-keys -t "$session" Enter 2>/dev/null
      echo -e "${GREEN}[bot-runner] Auto-accepted trust prompt.${NC}"
      return 0
    fi
    # If we see "Listening", CC started fine without trust prompt
    if echo "$content" | grep -q "Listening for channel"; then
      return 0
    fi
  done
}

# Main loop
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Bot Runner: $BOT_NAME${NC}"
echo -e "${GREEN}  Channel: $STATE_DIR${NC}"
echo -e "${GREEN}  Workdir: $BOT_WORKDIR${NC}"
echo -e "${GREEN}  PID: $$${NC}"
echo -e "${GREEN}============================================${NC}"

export TELEGRAM_STATE_DIR="$STATE_DIR"

# Cleanup: kill all child processes (MCP plugins, bun, node) when bot-runner exits
cleanup_children() {
  echo -e "${YELLOW}[bot-runner] Cleaning up child processes...${NC}"
  # Kill entire process group — catches all descendants
  pkill -P $$ 2>/dev/null
  # Also kill any orphaned bun/node processes from our claude sessions
  # by checking if their TELEGRAM_STATE_DIR matches ours
  sleep 1
  pkill -P $$ 2>/dev/null  # second pass for stragglers
  echo -e "${GREEN}[bot-runner] Cleanup complete.${NC}"
}
trap cleanup_children EXIT SIGTERM SIGINT SIGHUP

while true; do
  RESTART_COUNT=$((RESTART_COUNT + 1))
  check_rapid_restart

  echo ""
  echo -e "${YELLOW}[bot-runner] Starting claude (attempt #$RESTART_COUNT)...${NC}"
  patch_plugin

  cd "$BOT_WORKDIR"
  CLAUDE_ARGS="--channels plugin:telegram@claude-plugins-official"

  # Start trust auto-accepter in background
  auto_accept_trust &
  TRUST_PID=$!

  # Use --continue to resume the last session in this workdir.
  # Each bot has its own workdir, so --continue always finds the right session.
  # First run: no session exists, --continue fails → start fresh.
  echo -e "${GREEN}[bot-runner] claude --continue $CLAUDE_ARGS (workdir: $BOT_WORKDIR)${NC}"
  claude --continue $CLAUDE_ARGS
  EXIT_CODE=$?

  if [ $EXIT_CODE -eq 1 ] && [ $RESTART_COUNT -le 2 ]; then
    # --continue failed (no previous session). Start fresh.
    echo -e "${YELLOW}[bot-runner] No previous session, starting fresh...${NC}"
    auto_accept_trust &
    TRUST_PID2=$!
    claude $CLAUDE_ARGS
    EXIT_CODE=$?
    kill $TRUST_PID2 2>/dev/null
  fi

  # Clean up trust accepter
  kill $TRUST_PID 2>/dev/null

  echo -e "${YELLOW}[bot-runner] Claude exited with code $EXIT_CODE${NC}"

  # Kill any orphaned MCP plugin processes left behind by the exited claude session.
  # These are bun/node children that didn't exit when claude stopped.
  echo -e "${YELLOW}[bot-runner] Killing stale MCP processes...${NC}"
  pkill -f "bun.*server.ts" -P 1 2>/dev/null  # orphaned bun (PPID=1)
  pkill -f "notebooklm-mcp" -P 1 2>/dev/null  # orphaned notebooklm

  echo -e "${YELLOW}[bot-runner] Restarting in 5 seconds...${NC}"
  sleep 5
done
