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

## Missing dependencies: install, don't bypass

When a runtime import or shell command fails because a dependency is missing (e.g., `ModuleNotFoundError`, `command not found`), the default action is to **install it**, not to silently work around it.

- Python on this VPS: `pip install --break-system-packages <pkg>` (system Python is PEP 668 managed)
- Node/Bun: `npm i <pkg>` or `bun add <pkg>` in the project dir
- Briefly tell the user what you added in your reply ("装了 X 才能读 Y")
- Only bypass if the install genuinely fails — and then explicitly flag it, don't pretend it worked
- Exception: confirm first if the install would touch a sensitive system area or has security implications

**Why this rule exists:** 2026-05-06 — origin-qiushen hit `ModuleNotFoundError: pypdf/PyPDF2` reading a user PDF, silently bypassed without telling anyone. User: "以后如果遇到读不了的，就可以自行安装，不要默认绕过." Quietly clipping capabilities makes gaps invisible.
