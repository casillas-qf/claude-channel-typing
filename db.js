#!/usr/bin/env node

const Database = require("better-sqlite3");
const path = require("path");
const fs = require("fs");

const DB_PATH = path.join(__dirname, "history.db");

function getDb() {
  const db = new Database(DB_PATH);
  db.pragma("journal_mode = WAL");
  db.pragma("busy_timeout = 5000");

  // Create tables if not exist
  db.exec(`
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      channel TEXT NOT NULL,
      chat_id TEXT NOT NULL,
      message_id TEXT,
      role TEXT NOT NULL,
      user_name TEXT,
      content TEXT NOT NULL,
      timestamp TEXT NOT NULL,
      session_id TEXT,
      has_image INTEGER DEFAULT 0,
      image_path TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_channel_ts ON messages(channel, timestamp DESC);
    CREATE INDEX IF NOT EXISTS idx_chat_id ON messages(chat_id, timestamp DESC);
    CREATE INDEX IF NOT EXISTS idx_message_id ON messages(channel, message_id);
  `);

  // FTS5 virtual table for full-text search (trigram for CJK support)
  db.exec(`
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
      content,
      channel,
      chat_id,
      role,
      content_rowid='id',
      tokenize='trigram'
    );

    -- Triggers to keep FTS in sync
    CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(rowid, content, channel, chat_id, role)
      VALUES (new.id, new.content, new.channel, new.chat_id, new.role);
    END;

    CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
      INSERT INTO messages_fts(messages_fts, rowid, content, channel, chat_id, role)
      VALUES ('delete', old.id, old.content, old.channel, old.chat_id, old.role);
    END;
  `);

  return db;
}

// Save a message
function saveMessage(db, msg) {
  const stmt = db.prepare(`
    INSERT INTO messages (channel, chat_id, message_id, role, user_name, content, timestamp, session_id, has_image, image_path)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `);
  return stmt.run(
    msg.channel,
    msg.chat_id,
    msg.message_id || null,
    msg.role,
    msg.user_name || null,
    msg.content,
    msg.timestamp || new Date().toISOString(),
    msg.session_id || null,
    msg.has_image ? 1 : 0,
    msg.image_path || null
  );
}

// Get recent messages for a channel/chat
function getRecent(db, { channel, chat_id, limit = 50 }) {
  const stmt = db.prepare(`
    SELECT * FROM messages
    WHERE channel = ? AND chat_id = ?
    ORDER BY timestamp DESC
    LIMIT ?
  `);
  return stmt.all(channel, chat_id, limit).reverse();
}

// Full-text search (trigram needs 3+ chars, fallback to LIKE for short queries)
function search(db, { query, channel, chat_id, limit = 20 }) {
  let sql, params;

  if (query.length >= 3) {
    // Use FTS5 trigram for 3+ character queries
    sql = `
      SELECT m.* FROM messages m
      JOIN messages_fts f ON m.id = f.rowid
      WHERE messages_fts MATCH ?
    `;
    params = [query];
  } else {
    // Fallback to LIKE for short queries
    sql = `SELECT * FROM messages m WHERE m.content LIKE ?`;
    params = [`%${query}%`];
  }

  if (channel) {
    sql += " AND m.channel = ?";
    params.push(channel);
  }
  if (chat_id) {
    sql += " AND m.chat_id = ?";
    params.push(chat_id);
  }

  sql += " ORDER BY m.timestamp DESC LIMIT ?";
  params.push(limit);

  const stmt = db.prepare(sql);
  return stmt.all(...params);
}

// Get all channels
function getChannels(db) {
  const stmt = db.prepare(`
    SELECT channel, chat_id, COUNT(*) as msg_count,
           MAX(timestamp) as last_active
    FROM messages
    GROUP BY channel, chat_id
    ORDER BY last_active DESC
  `);
  return stmt.all();
}

// Get conversation context (for loading into new session)
function getContext(db, { channel, chat_id, hours = 24, limit = 100 }) {
  const since = new Date(Date.now() - hours * 3600 * 1000).toISOString();
  const stmt = db.prepare(`
    SELECT role, user_name, content, timestamp, has_image
    FROM messages
    WHERE channel = ? AND chat_id = ? AND timestamp > ?
    ORDER BY timestamp ASC
    LIMIT ?
  `);
  return stmt.all(channel, chat_id, since, limit);
}

// Lookup a message by message_id (for resolving reply_to references)
function lookupByMessageId(db, { channel, chat_id, message_id }) {
  const stmt = db.prepare(`
    SELECT * FROM messages
    WHERE chat_id = ? AND message_id = ?
    ORDER BY timestamp DESC
    LIMIT 1
  `);
  return stmt.get(chat_id, message_id) || null;
}

// CLI interface
if (require.main === module) {
  const args = process.argv.slice(2);
  const cmd = args[0];
  const db = getDb();

  switch (cmd) {
    case "save": {
      const data = JSON.parse(fs.readFileSync("/dev/stdin", "utf-8"));
      const result = saveMessage(db, data);
      console.log(JSON.stringify({ id: result.lastInsertRowid }));
      break;
    }
    case "recent": {
      const channel = args[1] || "telegram";
      const chat_id = args[2] || "";
      const limit = parseInt(args[3]) || 50;
      const messages = getRecent(db, { channel, chat_id, limit });
      console.log(JSON.stringify(messages, null, 2));
      break;
    }
    case "search": {
      const query = args[1];
      const channel = args[2] || undefined;
      const results = search(db, { query, channel });
      console.log(JSON.stringify(results, null, 2));
      break;
    }
    case "context": {
      const channel = args[1] || "telegram";
      const chat_id = args[2] || "";
      const hours = parseInt(args[3]) || 24;
      const messages = getContext(db, { channel, chat_id, hours });
      // Format for loading into conversation
      const formatted = messages.map((m) => {
        const prefix = m.role === "user" ? `[${m.user_name || "User"}]` : "[Assistant]";
        const time = m.timestamp.slice(0, 16).replace("T", " ");
        return `${time} ${prefix}: ${m.content}`;
      });
      console.log(formatted.join("\n\n"));
      break;
    }
    case "channels": {
      const channels = getChannels(db);
      console.log(JSON.stringify(channels, null, 2));
      break;
    }
    case "stats": {
      const total = db.prepare("SELECT COUNT(*) as count FROM messages").get();
      const channels = getChannels(db);
      console.log(`Total messages: ${total.count}`);
      console.log(`Channels:`);
      channels.forEach((c) => {
        console.log(`  ${c.channel}/${c.chat_id}: ${c.msg_count} msgs, last active: ${c.last_active}`);
      });
      break;
    }
    case "lookup": {
      const chat_id = args[1];
      const message_id = args[2];
      if (!chat_id || !message_id) {
        console.log("Usage: node db.js lookup <chat_id> <message_id>");
        break;
      }
      const msg = lookupByMessageId(db, { chat_id, message_id });
      console.log(msg ? JSON.stringify(msg, null, 2) : "null");
      break;
    }
    default:
      console.log(`Usage:
  node db.js save          < JSON   Save a message (pipe JSON to stdin)
  node db.js recent [channel] [chat_id] [limit]   Get recent messages
  node db.js search "query" [channel]              Full-text search
  node db.js context [channel] [chat_id] [hours]   Get context for new session
  node db.js lookup <chat_id> <message_id>         Lookup message by ID
  node db.js channels                              List all channels
  node db.js stats                                 Show statistics`);
  }

  db.close();
}

module.exports = { getDb, saveMessage, getRecent, search, getChannels, getContext, lookupByMessageId };
