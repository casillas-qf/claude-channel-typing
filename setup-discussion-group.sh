#!/bin/bash
set -e

# ============================================================
# Discussion Group Setup — Multi-Agent Group Discussion System
#
# Sets up a team of 4 bots (orchestrator + 3 experts) for
# collaborative group discussions in Telegram.
#
# Usage:
#   bash setup-discussion-group.sh --tokens
#   bash setup-discussion-group.sh --group-id GROUP_ID
#   bash setup-discussion-group.sh --full GROUP_ID
#
# Steps:
#   1. Run --tokens to configure bot tokens
#   2. Add all bots to a Telegram group
#   3. Run --group-id GROUP_ID to configure group access
#   4. Start all bots and pair them
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CUSTOM_DIR="$HOME/.claude/plugins/custom/telegram-typing"
CHANNELS_DIR="$HOME/.claude/channels"
WORKDIRS_DIR="$HOME/.claude/bot-workdirs"
BOT_MANAGER="$HOME/.claude/bot-manager"
PERSONAS_DIR="$SCRIPT_DIR/personas"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# The 4 roles and their default bot names
ROLES=("orchestrator" "engineer" "product" "critic")
ROLE_LABELS=("西神·主持" "西神·工程师" "西神·产品前端" "西神·批判者")
ROLE_TYPES=("moderator" "expert" "expert" "expert")
# Discussion delays in seconds (orchestrator=0, experts staggered)
ROLE_DELAYS=(0 30 60 90)

show_help() {
  echo "=== Discussion Group Setup ==="
  echo ""
  echo "Usage:"
  echo "  bash setup-discussion-group.sh --tokens                 Configure bot tokens"
  echo "  bash setup-discussion-group.sh --group-id GROUP_ID      Configure group access"
  echo "  bash setup-discussion-group.sh --full GROUP_ID           Full setup (tokens + group)"
  echo "  bash setup-discussion-group.sh --start                   Start all discussion bots"
  echo "  bash setup-discussion-group.sh --stop                    Stop all discussion bots"
  echo "  bash setup-discussion-group.sh --status                  Check bot status"
  echo ""
  echo "Roles:"
  for i in "${!ROLES[@]}"; do
    echo "  ${ROLES[$i]} — ${ROLE_LABELS[$i]} (${ROLE_TYPES[$i]})"
  done
}

setup_tokens() {
  echo -e "${GREEN}=== Configuring Bot Tokens ===${NC}"
  echo ""

  for i in "${!ROLES[@]}"; do
    local role="${ROLES[$i]}"
    local label="${ROLE_LABELS[$i]}"
    local state_dir="$CHANNELS_DIR/telegram-$role"

    if [ -f "$state_dir/.env" ]; then
      local existing_token=$(grep TELEGRAM_BOT_TOKEN "$state_dir/.env" | cut -d= -f2)
      local result=$(curl -s "https://api.telegram.org/bot$existing_token/getMe" 2>/dev/null)
      if echo "$result" | grep -q '"ok":true'; then
        local username=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null || echo "?")
        echo -e "${GREEN}[$role] Already configured: @$username${NC}"
        continue
      fi
    fi

    echo -e "${CYAN}[$role] ${label}${NC}"
    echo -n "  Enter bot token (or press Enter to skip): "
    read -r token

    if [ -z "$token" ]; then
      echo "  Skipped."
      continue
    fi

    mkdir -p "$state_dir"
    echo "TELEGRAM_BOT_TOKEN=$token" > "$state_dir/.env"
    chmod 600 "$state_dir/.env"

    # Validate
    local result=$(curl -s "https://api.telegram.org/bot$token/getMe" 2>/dev/null)
    if echo "$result" | grep -q '"ok":true'; then
      local username=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null || echo "?")
      echo -e "  ${GREEN}Token valid: @$username${NC}"
    else
      echo -e "  ${YELLOW}WARNING: Token validation failed.${NC}"
    fi
  done

  echo ""
  echo -e "${GREEN}Token setup complete.${NC}"
  echo "Next: Add all bots to a Telegram group, then run:"
  echo "  bash setup-discussion-group.sh --group-id GROUP_ID"
}

setup_group() {
  local group_id="$1"
  if [ -z "$group_id" ]; then
    echo "ERROR: Group ID required."
    echo "  Get it by adding @RawDataBot to the group temporarily, or check bot logs."
    exit 1
  fi

  echo -e "${GREEN}=== Configuring Group Access (Group: $group_id) ===${NC}"
  echo ""

  # Collect all bot usernames for cross-referencing in CLAUDE.md
  declare -a bot_usernames=()
  for i in "${!ROLES[@]}"; do
    local role="${ROLES[$i]}"
    local state_dir="$CHANNELS_DIR/telegram-$role"
    local username="unknown"
    if [ -f "$state_dir/.env" ]; then
      local token=$(grep TELEGRAM_BOT_TOKEN "$state_dir/.env" | cut -d= -f2)
      local result=$(curl -s "https://api.telegram.org/bot$token/getMe" 2>/dev/null)
      if echo "$result" | grep -q '"ok":true'; then
        username=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null || echo "unknown")
      fi
    fi
    bot_usernames+=("$username")
  done

  for i in "${!ROLES[@]}"; do
    local role="${ROLES[$i]}"
    local label="${ROLE_LABELS[$i]}"
    local role_type="${ROLE_TYPES[$i]}"
    local delay="${ROLE_DELAYS[$i]}"
    local state_dir="$CHANNELS_DIR/telegram-$role"

    if [ ! -f "$state_dir/.env" ]; then
      echo -e "${YELLOW}[$role] No token configured, skipping.${NC}"
      continue
    fi

    echo -e "${CYAN}[$role] ${label} — role: $role_type, delay: ${delay}s${NC}"

    # Create/update access.json with group config
    local access_file="$state_dir/access.json"
    local require_mention="true"
    if [ "$role_type" = "moderator" ]; then
      require_mention="false"
    fi

    # Build group policy JSON
    local group_policy="{\"requireMention\": $require_mention, \"allowFrom\": [], \"role\": \"$role_type\""
    if [ "$delay" -gt 0 ]; then
      group_policy="$group_policy, \"discussionDelay\": $delay"
    fi
    group_policy="$group_policy}"

    if [ -f "$access_file" ]; then
      # Update existing access.json — add/update group entry
      python3 -c "
import json
with open('$access_file', 'r') as f:
    a = json.load(f)
groups = a.setdefault('groups', {})
groups['$group_id'] = json.loads('$group_policy')
with open('$access_file', 'w') as f:
    json.dump(a, f, indent=2); f.write('\n')
print('  Updated access.json')
"
    else
      # Create new access.json
      cat > "$access_file" <<EOFACCESS
{
  "dmPolicy": "pairing",
  "allowFrom": [],
  "groups": {
    "$group_id": $group_policy
  }
}
EOFACCESS
      chmod 600 "$access_file"
      echo "  Created access.json"
    fi

    # Create bot workdir with CLAUDE.md persona
    local workdir="$WORKDIRS_DIR/$role"
    mkdir -p "$workdir"

    local persona_file="$PERSONAS_DIR/$role.CLAUDE.md"
    if [ -f "$persona_file" ]; then
      # Replace placeholder bot usernames in CLAUDE.md
      local claude_md="$workdir/CLAUDE.md"
      cp "$persona_file" "$claude_md"

      # Append bot roster to CLAUDE.md
      {
        echo ""
        echo "## Team Roster"
        echo ""
        echo "The following bots are in the discussion group:"
        for j in "${!ROLES[@]}"; do
          echo "- @${bot_usernames[$j]} — ${ROLE_LABELS[$j]} (${ROLES[$j]})"
        done
        echo ""
        echo "Use @username to mention them in group discussions."
      } >> "$claude_md"

      echo "  Created CLAUDE.md with ${label} persona"
    else
      echo -e "  ${YELLOW}Persona file not found: $persona_file${NC}"
    fi
  done

  echo ""
  echo -e "${GREEN}Group configuration complete.${NC}"
  echo ""
  echo "Next steps:"
  echo "  1. Start all bots:  bash setup-discussion-group.sh --start"
  echo "  2. In the group, each bot will ask for pairing"
  echo "  3. In each bot's CLI session, run: /telegram:access pair <code>"
  echo "  4. Lock access: /telegram:access policy allowlist"
}

start_bots() {
  echo -e "${GREEN}=== Starting Discussion Bots ===${NC}"

  # Ensure bot-runner is installed
  mkdir -p "$BOT_MANAGER"
  if [ -f "$SCRIPT_DIR/bot-runner.sh" ]; then
    cp "$SCRIPT_DIR/bot-runner.sh" "$BOT_MANAGER/bot-runner.sh"
    chmod +x "$BOT_MANAGER/bot-runner.sh"
  fi

  # Patch plugin
  if [ -f "$CUSTOM_DIR/server.ts" ]; then
    for target in \
      "$HOME/.claude/plugins/cache/claude-plugins-official/telegram/"*/server.ts \
      "$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"; do
      if [ -f "$target" ]; then
        cp "$CUSTOM_DIR/server.ts" "$target" 2>/dev/null
      fi
    done
    echo "Plugin patched."
  fi

  for i in "${!ROLES[@]}"; do
    local role="${ROLES[$i]}"
    local label="${ROLE_LABELS[$i]}"
    local state_dir="$CHANNELS_DIR/telegram-$role"
    local session="bot-$role"

    if [ ! -f "$state_dir/.env" ]; then
      echo -e "${YELLOW}[$role] No token, skipping.${NC}"
      continue
    fi

    # Check if already running
    if tmux has-session -t "$session" 2>/dev/null; then
      echo -e "${GREEN}[$role] Already running in tmux session '$session'${NC}"
      continue
    fi

    echo -e "${CYAN}[$role] Starting ${label} in tmux session '$session'...${NC}"
    tmux new-session -d -s "$session" "bash $BOT_MANAGER/bot-runner.sh $role"
    echo -e "${GREEN}[$role] Started.${NC}"
  done

  echo ""
  echo "All bots started. Check status with:"
  echo "  bash setup-discussion-group.sh --status"
}

stop_bots() {
  echo -e "${YELLOW}=== Stopping Discussion Bots ===${NC}"

  for role in "${ROLES[@]}"; do
    local session="bot-$role"
    if tmux has-session -t "$session" 2>/dev/null; then
      tmux send-keys -t "$session" "/exit" Enter
      echo "[$role] Sent /exit"
      sleep 2
      tmux kill-session -t "$session" 2>/dev/null
      echo "[$role] Session killed"
    else
      echo "[$role] Not running"
    fi
  done
}

show_status() {
  echo "=== Discussion Bot Status ==="
  echo ""
  for i in "${!ROLES[@]}"; do
    local role="${ROLES[$i]}"
    local label="${ROLE_LABELS[$i]}"
    local session="bot-$role"
    local state_dir="$CHANNELS_DIR/telegram-$role"

    local token_status="${RED}no token${NC}"
    local username="?"
    if [ -f "$state_dir/.env" ]; then
      local token=$(grep TELEGRAM_BOT_TOKEN "$state_dir/.env" | cut -d= -f2)
      local result=$(curl -s "https://api.telegram.org/bot$token/getMe" 2>/dev/null)
      if echo "$result" | grep -q '"ok":true'; then
        username=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null || echo "?")
        token_status="${GREEN}@$username${NC}"
      else
        token_status="${YELLOW}invalid token${NC}"
      fi
    fi

    local run_status="${RED}stopped${NC}"
    if tmux has-session -t "$session" 2>/dev/null; then
      run_status="${GREEN}running${NC}"
    fi

    echo -e "  [$role] ${label}  token: $token_status  status: $run_status"
  done
}

# --- Main ---

case "${1:-}" in
  --tokens)
    setup_tokens
    ;;
  --group-id)
    setup_group "$2"
    ;;
  --full)
    setup_tokens
    echo ""
    setup_group "$2"
    ;;
  --start)
    start_bots
    ;;
  --stop)
    stop_bots
    ;;
  --status)
    show_status
    ;;
  --help|-h|"")
    show_help
    ;;
  *)
    echo "Unknown option: $1"
    show_help
    exit 1
    ;;
esac
