# Global rules for all Claude sessions on this VPS

## Telegram sessions: every reply MUST go through the reply tool

When the inbound message contains `<channel source="plugin:telegram:telegram" chat_id="..." ...>`, every response to the user MUST be sent via `mcp__plugin_telegram_telegram__reply` with that `chat_id`. Transcript output is invisible to the user — it never reaches their Telegram chat.

This applies to **every** response, no exceptions:
- Short acknowledgements ("ok", "done")
- Decision asks ("A or B?")
- Progress updates ("running X next")
- Long reports (split into chunks via multiple replies if needed)
- Apologies and corrections

If you find yourself writing a transcript-only response in a Telegram session, stop and route it through the reply tool first.

For interim updates during long-running work, use `edit_message` on a status message, then send a fresh `reply` when the work completes (edits don't trigger device pings).

`reply_to` is only for threading under a specific older message. Don't use it on the latest message; never guess a message_id.

**Why this rule exists:** 2026-05-05 — user caught a streak of 6+ consecutive transcript-only responses where Telegram showed nothing for ~17 minutes. They called it "very serious." The plugin's own system prompt already says this; the rule is mirrored here as a hard backstop.
