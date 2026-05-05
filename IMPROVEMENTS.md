# claude-channel-typing Improvement Backlog

Tracked improvements identified during real-world use.

## MCP/bun multi-poller race — sibling buns share token, drop messages

**Status:** open · **Filed:** 2026-05-05 · **Severity:** high (silent message loss) · **Difficulty:** medium

### Symptom

After running for a few hours, a single bot can end up with 2+ `bun run …telegram` processes simultaneously polling the same Telegram bot token. Telegram permits exactly one `getUpdates` consumer per token, so:

- Each poll gets routed to whichever bun asks first
- The other bun gets `409 Conflict` and retries
- User-sent messages are randomly distributed across pollers
- Only the bun whose stdio is connected to claude → MCP forwards the update upward; messages caught by the orphan are written to `inbox/` but never reach the LLM
- Net effect: silent message loss, ~50% miss rate

### Today's diagnosis (2026-05-05)

- Bot `sanfan-xishen` had two bun processes:
  - PID 9779 (claude 9697's child, alive 6h+, "legitimate")
  - PID 97889 (PPID=1 orphan after parent died, alive 1h45m)
- Both env vars `TELEGRAM_STATE_DIR=/root/.claude/channels/telegram-sanfan-xishen` and same token
- `inbox/` had 5 identical 171KB images saved at 07:08:48 UTC — same Telegram update fetched by both pollers
- User's text messages around that window never surfaced in the LLM context
- Killing 97889 didn't permanently fix it: claude 9697 immediately spawned new buns (125964, 125864, 126107, 126273, 126375) over the next minute. Loop only stopped after 4-5 manual kills

### Why the existing patch (639a10a) doesn't fully fix it

The patch I shipped earlier today (commit 639a10a "Fix MCP stdio race: don't kill sibling bun, only true orphans") solved one half of the problem — preventing newly-spawned siblings from killing each other on the way up. But it leaves a different gap open:

- Two siblings can coexist forever (both PPID=N, neither orphaned)
- Telegram's 409 doesn't terminate either — bun just retries on 409
- The patch comment said "Telegram itself will resolve via 409" — that turns out to be wrong; 409 doesn't trigger termination, just retry

### Improvement candidates

1. **File-lock single-instance enforcement (recommended)**
   - On startup, take an exclusive `flock(2)` on `${STATE_DIR}/bot.lock`
   - If lock held by an alive process → wait briefly for it to release (which would happen if it's exiting); if still held after grace → exit with clear error
   - Older bun keeps the lock; newer bun bows out cleanly
   - Robust against orphans, siblings, race respawns

2. **First-mover wins via PID file**
   - Write `bot.pid` atomically with `O_EXCL` on startup
   - If another PID already there and alive → exit (don't try to "replace")
   - Clean up `bot.pid` on shutdown
   - Less robust than `flock` (PID file can lie if process crashed without cleanup) but simpler

3. **Suppress claude-side respawning**
   - Investigate why `claude --channels` respawns bun even when one is alive (heartbeat? MCP init failure?)
   - May require change in claude itself (out of this repo's scope)

4. **Health-aware self-yield**
   - Each bun periodically checks if a SIBLING with same TELEGRAM_STATE_DIR exists
   - If yes AND its own etime is shorter → exit voluntarily
   - "Newer yields to older" rule
   - Easy to implement; depends on `/proc` so Linux-only

### Recommendation

#1 (flock) is the right answer. It's the standard Unix solution for "only one of us at a time" and survives crashes (lock auto-released on process exit). Implementation is ~10 lines around the existing startup.

### Manual workaround (until fix lands)

When messages start dropping:

```bash
# Find duplicate buns for sanfan-xishen
for pid in $(pgrep -f "bun.*telegram"); do
  dir=$(cat /proc/$pid/environ 2>/dev/null | tr '\0' '\n' | grep '^TELEGRAM_STATE_DIR=' | cut -d= -f2)
  echo "PID $pid → $dir"
done

# Kill orphans (PPID=1) only:
ps -e -o pid,ppid,cmd | awk '/bun.*telegram/ && $2==1 {print $1}' | xargs -r kill -KILL
```

The cleanest reset: kill the bot's tmux session and let `bot-runner.sh` start a fresh one.

### Recurrence (2026-05-05 17:25 BJT) — "post-startup orphan" gap

The same class of bug bit `sanfan-xishen` again, ~2h after the previous fix attempt. New data point:

- Orphan bun PID 97901, PPID=1, etime 2h19m, env `TELEGRAM_STATE_DIR=/root/.claude/channels/telegram-sanfan-xishen`
- Legitimate bun pair (PID 136602/136607) was alive and well, etime 6m, owned by claude 136556
- User's message msg_id 3526 ("那就按你说的弄") never reached the LLM context — confirmed dropped
- Killing 97901 fixed it; 30s observation window after kill showed no respawn

**Why today's fix didn't catch it:** commit 639a10a's stale-poller check runs only **at bun startup**. The legitimate bun (136602) started cleanly when the orphan didn't yet exist. The orphan came into being later — most likely from an earlier claude session that died and left its bun reparented to init. Once the legitimate bun is past startup, nothing in the codebase ever looks for orphans again.

**Refined recommendation, ranked:**

1. **Periodic orphan scan (low-effort interim fix)** — Add a 60s setInterval to bun's main loop: enumerate `/proc/*/environ` for entries matching its own `TELEGRAM_STATE_DIR`, skip self, and if any with PPID=1 found → SIGTERM it. Survives the "post-startup orphan" case. ~15 LoC.

2. **flock-based single instance (proper fix, candidate #1 above)** — Still the right long-term answer; orphans can't acquire the lock so they'd self-exit. But heavier change.

The two are complementary: ship #1 now to stop the bleeding, plan #2 for the next iteration.
