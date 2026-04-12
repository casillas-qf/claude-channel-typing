#!/bin/bash
set -e

# ============================================================
# Telegram Typing Heartbeat Plugin — One-click Installer
#
# Supports multiple bots on the same machine.
#
# Usage:
#   bash install.sh                           # install core + interactive bot setup
#   bash install.sh --add-bot NAME TOKEN      # add a named bot
#   bash install.sh --add-bot work 123:AAH... # example
#   bash install.sh --setup-aliases           # auto-generate aliases for all configured bots
#   bash install.sh --install-runner          # install bot-runner.sh for auto-restart
#   bash install.sh --full-setup              # full install + aliases + runner (one-click for new machines)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CUSTOM_DIR="$HOME/.claude/plugins/custom/telegram-typing"
SETTINGS="$HOME/.claude/settings.json"

# --- Functions ---

check_prereqs() {
  echo "[prereq] Checking prerequisites..."
  if ! command -v claude &>/dev/null; then
    echo "ERROR: claude not found. Install: npm install -g @anthropic-ai/claude-code"
    exit 1
  fi
  if ! command -v bun &>/dev/null; then
    echo "Bun not found. Installing..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
  fi
  echo "  claude: $(which claude)"
  echo "  bun: $(which bun)"
}

patch_plugin() {
  echo "[patch] Patching server.ts with typing heartbeat..."
  mkdir -p "$CUSTOM_DIR"
  cp "$SCRIPT_DIR/server.ts" "$CUSTOM_DIR/server.ts"

  local patched=0
  for target in \
    "$HOME/.claude/plugins/cache/claude-plugins-official/telegram/"*/server.ts \
    "$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"; do
    if [ -f "$target" ]; then
      cp "$CUSTOM_DIR/server.ts" "$target"
      echo "  Patched: $target"
      patched=$((patched + 1))
    fi
  done

  if [ $patched -eq 0 ]; then
    echo "  WARNING: No target found. Install official plugin first:"
    echo "    In Claude Code: /plugin install telegram@claude-plugins-official"
  fi
}

configure_permissions() {
  echo "[perms] Configuring auto-allow permissions..."
  if [ -f "$SETTINGS" ]; then
    if grep -q "mcp__plugin_telegram_telegram__" "$SETTINGS" 2>/dev/null; then
      echo "  Already configured."
    else
      python3 -c "
import json
with open('$SETTINGS', 'r') as f:
    s = json.load(f)
p = s.setdefault('permissions', {})
a = p.setdefault('allow', [])
r = 'mcp__plugin_telegram_telegram__*'
if r not in a: a.append(r)
with open('$SETTINGS', 'w') as f:
    json.dump(s, f, indent=2); f.write('\n')
print('  Added: ' + r)
"
    fi
  else
    cat > "$SETTINGS" <<'EOF'
{
  "permissions": {
    "allow": [
      "mcp__plugin_telegram_telegram__*"
    ]
  }
}
EOF
    echo "  Created $SETTINGS"
  fi
}

add_bot() {
  local name="$1"
  local token="$2"
  local state_dir="$HOME/.claude/channels/telegram-$name"

  echo "[bot:$name] Setting up bot '$name'..."
  mkdir -p "$state_dir"
  echo "TELEGRAM_BOT_TOKEN=$token" > "$state_dir/.env"
  chmod 600 "$state_dir/.env"

  # Validate token
  local result
  result=$(curl -s "https://api.telegram.org/bot$token/getMe" 2>/dev/null)
  if echo "$result" | grep -q '"ok":true'; then
    local username
    username=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null || echo "unknown")
    echo "  Token valid: @$username"
  else
    echo "  WARNING: Token validation failed. Check your token."
  fi

  echo "  State dir: $state_dir"
  echo "  Launch with: bash ~/.claude/plugins/custom/telegram-typing/launch.sh $name"
}

create_launcher() {
  echo "[launcher] Creating launch script..."
  cat > "$CUSTOM_DIR/launch.sh" <<'LAUNCH'
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
LAUNCH
  chmod +x "$CUSTOM_DIR/launch.sh"
  echo "  Created: $CUSTOM_DIR/launch.sh"
}

setup_aliases() {
  echo "[aliases] Setting up shell aliases for all configured bots..."
  # Detect shell rc file
  local rc_file=""
  if [ -f "$HOME/.zshrc" ]; then
    rc_file="$HOME/.zshrc"
  elif [ -f "$HOME/.bashrc" ]; then
    rc_file="$HOME/.bashrc"
  else
    rc_file="$HOME/.bashrc"
    touch "$rc_file"
  fi

  local added=0
  local marker="# claude-channel-typing aliases"

  # Remove old alias block if exists (between markers)
  if grep -q "$marker" "$rc_file" 2>/dev/null; then
    sed -i.bak "/$marker BEGIN/,/$marker END/d" "$rc_file"
    rm -f "${rc_file}.bak"
    echo "  Removed old alias block."
  fi

  # Collect all bot names
  local bot_names=()
  for d in "$HOME/.claude/channels/telegram-"*/; do
    if [ -f "$d/.env" ]; then
      local name
      name=$(basename "$d" | sed 's/telegram-//')
      bot_names+=("$name")
    fi
  done

  if [ ${#bot_names[@]} -eq 0 ]; then
    echo "  No bots found in ~/.claude/channels/telegram-*/. Nothing to do."
    return
  fi

  # Write alias block
  {
    echo ""
    echo "$marker BEGIN"
    for name in "${bot_names[@]}"; do
      local alias_name="claude-${name}"
      echo "alias ${alias_name}=\"bash ~/.claude/plugins/custom/telegram-typing/launch.sh ${name}\""
      added=$((added + 1))
    done
    echo "$marker END"
  } >> "$rc_file"

  echo "  Added $added alias(es) to $rc_file:"
  for name in "${bot_names[@]}"; do
    echo "    claude-${name} → launch.sh ${name}"
  done
  echo "  Run: source $rc_file"
}

install_runner() {
  echo "[runner] Installing bot-runner.sh..."
  local runner_dir="$HOME/.claude/bot-manager"
  mkdir -p "$runner_dir"
  if [ -f "$SCRIPT_DIR/bot-runner.sh" ]; then
    cp "$SCRIPT_DIR/bot-runner.sh" "$runner_dir/bot-runner.sh"
    chmod +x "$runner_dir/bot-runner.sh"
    echo "  Installed: $runner_dir/bot-runner.sh"
    echo ""
    echo "  Usage (run inside tmux):"
    echo "    bash ~/.claude/bot-manager/bot-runner.sh <bot-name>"
    echo ""
    echo "  Example with tmux:"
    echo "    tmux new-session -d -s bot-work 'bash ~/.claude/bot-manager/bot-runner.sh work'"
  else
    echo "  ERROR: bot-runner.sh not found in $SCRIPT_DIR"
    return 1
  fi
}

list_bots() {
  echo ""
  echo "Configured bots:"
  # Default bot
  if [ -f "$HOME/.claude/channels/telegram/.env" ]; then
    echo "  [default]  bash launch.sh"
  fi
  # Named bots
  for d in "$HOME/.claude/channels/telegram-"*/; do
    if [ -f "$d/.env" ]; then
      local name
      name=$(basename "$d" | sed 's/telegram-//')
      local token
      token=$(grep TELEGRAM_BOT_TOKEN "$d/.env" | cut -d= -f2)
      local username="?"
      local result
      result=$(curl -s "https://api.telegram.org/bot$token/getMe" 2>/dev/null)
      if echo "$result" | grep -q '"ok":true'; then
        username=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null || echo "?")
      fi
      echo "  [$name]  @$username  →  bash launch.sh $name"
    fi
  done
}

# --- Main ---

echo "=== Telegram Typing Heartbeat Plugin ==="
echo ""

# Handle subcommands
if [ "$1" = "--add-bot" ]; then
  if [ -z "$2" ] || [ -z "$3" ]; then
    echo "Usage: bash install.sh --add-bot NAME TOKEN"
    echo ""
    echo "Example:"
    echo "  bash install.sh --add-bot work 123456789:AAH..."
    echo "  bash install.sh --add-bot personal 987654321:BBX..."
    exit 1
  fi
  add_bot "$2" "$3"
  list_bots
  exit 0
fi

if [ "$1" = "--setup-aliases" ]; then
  setup_aliases
  exit 0
fi

if [ "$1" = "--install-runner" ]; then
  install_runner
  exit 0
fi

if [ "$1" = "--full-setup" ]; then
  # Full install + aliases + runner — one command for new machines
  check_prereqs
  echo ""
  patch_plugin
  echo ""
  configure_permissions
  echo ""
  create_launcher
  echo ""
  install_runner
  echo ""
  setup_aliases
  echo ""
  list_bots
  echo ""
  echo "=== Full setup complete ==="
  exit 0
fi

# Full install
check_prereqs
echo ""
patch_plugin
echo ""
configure_permissions
echo ""
create_launcher
echo ""

# Bot setup
PLUGIN_CACHE=$(find "$HOME/.claude/plugins/cache/claude-plugins-official/telegram" -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)
if [ -z "$PLUGIN_CACHE" ]; then
  echo "[NOTICE] Official plugin not found. Install it first:"
  echo "  In Claude Code: /plugin install telegram@claude-plugins-official"
  echo "  Then run this installer again."
  echo ""
fi

# Check for existing bots
existing_bots=0
[ -f "$HOME/.claude/channels/telegram/.env" ] && existing_bots=$((existing_bots + 1))
for d in "$HOME/.claude/channels/telegram-"*/; do
  [ -f "$d/.env" ] 2>/dev/null && existing_bots=$((existing_bots + 1))
done

if [ $existing_bots -eq 0 ]; then
  echo "[setup] No bots configured yet."
  echo ""
  echo "  Add your first bot:"
  echo "    bash install.sh --add-bot <NAME> <TOKEN>"
  echo ""
  echo "  Example (two bots):"
  echo "    bash install.sh --add-bot work 123456789:AAH..."
  echo "    bash install.sh --add-bot personal 987654321:BBX..."
  echo ""
  echo "  Then launch in separate terminals:"
  echo "    Terminal 1:  bash ~/.claude/plugins/custom/telegram-typing/launch.sh work"
  echo "    Terminal 2:  bash ~/.claude/plugins/custom/telegram-typing/launch.sh personal"
else
  list_bots
fi

echo ""
echo "=== Done ==="
