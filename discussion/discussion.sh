#!/bin/bash
# Discussion helper script — used by bots to manage discussion state
# Usage:
#   bash discussion.sh init "topic text" "orchestrator_decomposition"
#   bash discussion.sh assign <role> "task description"
#   bash discussion.sh respond <role> "response text"
#   bash discussion.sh status
#   bash discussion.sh get-task <role>
#   bash discussion.sh get-context
#   bash discussion.sh send-to-group <role> "message text"
#   bash discussion.sh notify-orchestrator <role> "done message"
#   bash discussion.sh clear

DISCUSSION_DIR="$HOME/.claude/discussion"
ACTIVE_FILE="$DISCUSSION_DIR/active.json"
CONFIG_FILE="$DISCUSSION_DIR/config.json"

# Read config
get_token() {
  local role="$1"
  python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['bots']['$role']['token'])"
}

get_group_id() {
  python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['group_id'])"
}

get_tmux_session() {
  local role="$1"
  python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['bots']['$role']['tmux_session'])"
}

get_label() {
  local role="$1"
  python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['bots']['$role']['label'])"
}

# Send a message to a tmux session with verification and retry.
# Sometimes tmux send-keys Enter is swallowed when claude's prompt isn't ready.
tmux_send_verified() {
  local session="$1"
  local message="$2"

  tmux send-keys -t "$session" "$message" Enter 2>/dev/null

  # Verify the prompt was accepted (look for processing indicators within 8s)
  local accepted=false
  for i in $(seq 1 8); do
    sleep 1
    if tmux capture-pane -t "$session" -p 2>/dev/null | grep -qE "Reading|Wrangling|Smooshing|Baking|Cooked|Sautéed|esc to interrupt|Zesting|Herding|Cogitat|Fiddle|Churning"; then
      accepted=true
      break
    fi
  done

  if [ "$accepted" = false ]; then
    # Retry: send Enter in case text is sitting at prompt
    tmux send-keys -t "$session" Enter 2>/dev/null
    sleep 2
    if ! tmux capture-pane -t "$session" -p 2>/dev/null | grep -qE "Reading|Wrangling|Smooshing|Baking|Cooked|Sautéed|esc to interrupt|Zesting|Herding|Cogitat|Fiddle|Churning"; then
      # Last resort: re-send full message
      tmux send-keys -t "$session" "$message" Enter 2>/dev/null
    fi
  fi
}

case "${1:-}" in
  init)
    # Initialize a new discussion
    topic="$2"
    decomposition="${3:-}"
    python3 -c "
import json, time
d = {
    'topic': '''$topic''',
    'decomposition': '''$decomposition''',
    'created_at': time.time(),
    'status': 'in_progress',
    'assignments': {},
    'responses': {},
    'summary': None
}
with open('$ACTIVE_FILE', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('Discussion initialized')
"
    ;;

  assign)
    role="$2"
    task="$3"
    python3 -c "
import json
with open('$ACTIVE_FILE', 'r') as f:
    d = json.load(f)
d['assignments']['$role'] = {'task': '''$task''', 'status': 'pending'}
with open('$ACTIVE_FILE', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('Assigned to $role')
"
    ;;

  respond)
    role="$2"
    response="$3"
    python3 -c "
import json, time
with open('$ACTIVE_FILE', 'r') as f:
    d = json.load(f)
# Append to discussion log (multi-round)
log = d.setdefault('discussion_log', [])
log.append({'role': '$role', 'text': '''$response''', 'ts': time.time()})
# Also update latest response for this role
d['responses']['$role'] = '''$response'''
if '$role' in d.get('assignments', {}):
    d['assignments']['$role']['status'] = 'done'
with open('$ACTIVE_FILE', 'w') as f:
    json.dump(d, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('Response recorded for $role')
"
    ;;

  status)
    if [ ! -f "$ACTIVE_FILE" ]; then
      echo "No active discussion"
      exit 0
    fi
    python3 -c "
import json
with open('$ACTIVE_FILE', 'r') as f:
    d = json.load(f)
print(f'Topic: {d[\"topic\"][:80]}')
print(f'Status: {d[\"status\"]}')
for role, a in d.get('assignments', {}).items():
    print(f'  {role}: {a[\"status\"]}')
print(f'Responses: {list(d.get(\"responses\", {}).keys())}')
"
    ;;

  get-task)
    role="$2"
    python3 -c "
import json
with open('$ACTIVE_FILE', 'r') as f:
    d = json.load(f)
a = d.get('assignments', {}).get('$role', {})
if a.get('status') == 'pending':
    print(a.get('task', ''))
else:
    print('')
"
    ;;

  get-context)
    python3 -c "
import json
with open('$ACTIVE_FILE', 'r') as f:
    d = json.load(f)
print(f'Topic: {d[\"topic\"]}')
if d.get('decomposition'):
    print(f'\nDecomposition:\n{d[\"decomposition\"]}')
# Show full discussion log (multi-round)
log = d.get('discussion_log', [])
if log:
    print('\n=== 讨论记录 ===')
    for entry in log:
        print(f'\n【{entry[\"role\"]}】')
        print(entry['text'])
else:
    # Fallback: show responses dict
    for role, resp in d.get('responses', {}).items():
        if resp:
            print(f'\n--- {role} ---')
            print(resp)
"
    ;;

  send-to-group)
    role="$2"
    message="$3"
    token=$(get_token "$role")
    group_id=$(get_group_id)
    label=$(get_label "$role")
    # Prepend role label to message
    full_message="【${label}】

${message}"
    # Send with rate limit protection (simple: just don't send more than 1/sec)
    curl -s "https://api.telegram.org/bot${token}/sendMessage" \
      -d "chat_id=${group_id}" \
      --data-urlencode "text=${full_message}" > /dev/null
    echo "Sent to group as ${label}"
    ;;

  notify-orchestrator)
    role="$2"
    message="${3:-$role completed}"
    session=$(get_tmux_session "orchestrator")
    # Use tmux send-keys to notify orchestrator (with verification)
    tmux_send_verified "$session" "[EXPERT_DONE] $role: $message"
    echo "Notified orchestrator"
    ;;

  dispatch)
    # Orchestrator dispatches task to an expert
    role="$2"
    task="$3"
    context="${4:-}"
    session=$(get_tmux_session "$role")

    # Write task to a temp file to avoid tmux send-keys length limits
    task_file="$DISCUSSION_DIR/task-${role}.txt"
    echo "$task" > "$task_file"
    if [ -n "$context" ]; then
      echo "" >> "$task_file"
      echo "--- 已有讨论内容 ---" >> "$task_file"
      echo "$context" >> "$task_file"
    fi

    # Send compact command to expert via tmux (with verification)
    tmux_send_verified "$session" "[DISCUSSION] 请阅读 $task_file 获取你的任务，完成后用 discussion.sh 发送结果"
    echo "Dispatched to $role"
    ;;

  relay)
    # Relay a message from one expert to another (for cross-discussion)
    from_role="$2"
    to_role="$3"
    message="$4"
    session=$(get_tmux_session "$to_role")
    from_label=$(get_label "$from_role")

    # Write to file to avoid tmux length limits
    relay_file="$DISCUSSION_DIR/relay-${to_role}.txt"
    echo "来自 ${from_label} 的回复：" > "$relay_file"
    echo "" >> "$relay_file"
    echo "$message" >> "$relay_file"

    tmux_send_verified "$session" "[DISCUSSION_REPLY] ${from_role} 回复了你，请阅读 $relay_file 并考虑是否回应"
    echo "Relayed from $from_role to $to_role"
    ;;

  broadcast)
    # Broadcast a message from one expert to ALL other experts
    from_role="$2"
    message="$3"
    from_label=$(get_label "$from_role")

    for role in orchestrator engineer product critic; do
      if [ "$role" != "$from_role" ]; then
        session=$(get_tmux_session "$role")
        relay_file="$DISCUSSION_DIR/relay-${role}.txt"
        echo "来自 ${from_label} 的发言：" > "$relay_file"
        echo "" >> "$relay_file"
        echo "$message" >> "$relay_file"
        tmux_send_verified "$session" "[DISCUSSION_REPLY] ${from_role} 发言了，请阅读 $relay_file 考虑是否回应（如果没有新观点可以不回复）"
      fi
    done
    echo "Broadcast from $from_role to all others"
    ;;

  stop)
    # Orchestrator signals discussion should end
    for role in engineer product critic; do
      session=$(get_tmux_session "$role")
      tmux_send_verified "$session" "[DISCUSSION_END] 主持人已结束讨论，不需要再回复"
    done
    echo "Stop signal sent to all experts"
    ;;

  clear)
    rm -f "$ACTIVE_FILE" "$DISCUSSION_DIR"/task-*.txt "$DISCUSSION_DIR"/relay-*.txt
    echo "Discussion cleared"
    ;;

  *)
    echo "Usage: bash discussion.sh {init|assign|respond|status|get-task|get-context|send-to-group|notify-orchestrator|dispatch|clear}"
    ;;
esac
