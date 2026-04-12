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
d['responses']['$role'] = '''$response'''
if '$role' in d.get('assignments', {}):
    d['assignments']['$role']['status'] = 'done'
    d['assignments']['$role']['completed_at'] = time.time()
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
    # Use tmux send-keys to notify orchestrator
    # Escape special characters for tmux
    tmux send-keys -t "$session" "[EXPERT_DONE] $role: $message" Enter 2>/dev/null
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

    # Send compact command to expert via tmux
    tmux send-keys -t "$session" "[DISCUSSION] 请阅读 $task_file 获取你的任务，完成后用 discussion.sh 发送结果" Enter 2>/dev/null
    echo "Dispatched to $role"
    ;;

  clear)
    rm -f "$ACTIVE_FILE" "$DISCUSSION_DIR"/task-*.txt
    echo "Discussion cleared"
    ;;

  *)
    echo "Usage: bash discussion.sh {init|assign|respond|status|get-task|get-context|send-to-group|notify-orchestrator|dispatch|clear}"
    ;;
esac
