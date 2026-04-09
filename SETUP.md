# 新电脑部署指南

## 前置条件

- macOS / Linux
- Node.js (>= 18)
- Claude Code (>= v2.1.80)，已登录 claude.ai 账号

## 安装（一次性）

### 第一步：解压

```bash
tar xzf telegram-typing-plugin.tar.gz
cd telegram-typing-plugin
```

### 第二步：安装官方 Telegram 插件

```bash
claude
```

在 session 里执行：

```
/plugin install telegram@claude-plugins-official
/reload-plugins
```

退出 session（Ctrl+C 或 /exit）。

### 第三步：运行安装脚本

```bash
bash install.sh
```

这会自动完成：patch typing 心跳、配置权限（不再弹确认框）、生成启动脚本。

## 日常使用

### 启动一个 bot

```bash
bash ~/.claude/plugins/custom/telegram-typing/launch.sh mybot
```

- 如果 `mybot` 是新名字，脚本会直接问你要 token，粘贴后自动保存并启动
- 如果 `mybot` 已经配过 token，直接启动

名字随便取：`1`、`2`、`work`、`personal`、`test` 都行，就是个文件夹后缀。

### 首次配对（每个 bot 只需一次）

1. 启动后，去 Telegram DM 你的 bot
2. Bot 回复 6 位配对码
3. 在 Claude Code session 里输入：`/telegram:access pair <配对码>`
4. 锁定：`/telegram:access policy allowlist`

### 同时跑两个 bot

```bash
# 终端 1
bash ~/.claude/plugins/custom/telegram-typing/launch.sh 1

# 终端 2
bash ~/.claude/plugins/custom/telegram-typing/launch.sh 2
```

首次启动每个 bot 时会分别问你要 token。两个 bot 的 token、配对、消息完全隔离。

### 建议加 alias

```bash
cat >> ~/.zshrc <<'EOF'
alias claude-1="bash ~/.claude/plugins/custom/telegram-typing/launch.sh 1"
alias claude-2="bash ~/.claude/plugins/custom/telegram-typing/launch.sh 2"
EOF
source ~/.zshrc
```

之后直接 `claude-1`、`claude-2`。

## Bot Token 怎么获取

1. 打开 Telegram，搜索 `@BotFather`
2. 发送 `/newbot`
3. 输入 bot 名称和 username
4. 复制 token（格式：`123456789:AAH...`）

每个 bot 需要一个独立的 token。

## 文件结构

```
安装后的目录结构：

~/.claude/plugins/custom/telegram-typing/
├── server.ts       # 带 typing 心跳的 MCP server
├── launch.sh       # 启动脚本
└── skills/
    ├── access/SKILL.md      # 配对/权限管理（支持多 bot）
    └── configure/SKILL.md   # token 配置（支持多 bot）

~/.claude/channels/
├── telegram-1/     ← bot 1 的状态
│   ├── .env        # token
│   ├── access.json # 配对信息（自动生成）
│   └── inbox/      # 收到的图片/文件
└── telegram-2/     ← bot 2 的状态
    ├── .env
    ├── access.json
    └── inbox/
```

## 完整流程示例（从零开始）

```bash
# 1. 解压安装
tar xzf telegram-typing-plugin.tar.gz
cd telegram-typing-plugin
claude                                    # 启动临时 session
# 在 session 里执行：
#   /plugin install telegram@claude-plugins-official
#   /reload-plugins
# 退出 session

# 2. 运行安装脚本
bash install.sh

# 3. 启动第一个 bot（会问你要 token）
bash ~/.claude/plugins/custom/telegram-typing/launch.sh 1
# 粘贴 token → 自动启动
# 去 Telegram DM bot → 拿配对码
# 在 session 里：/telegram:access pair <码>
# 锁定：/telegram:access policy allowlist

# 4. 开新终端，启动第二个 bot
bash ~/.claude/plugins/custom/telegram-typing/launch.sh 2
# 同上流程
```

## 故障排查

| 问题 | 原因 | 解决 |
|------|------|------|
| bot 不回复配对码 | token 没写入或 server 没启动 | 确认用 `launch.sh` 启动，启动时有 "Launching bot" 输出 |
| reply 每次要点确认 | 权限没配好 | 检查 `~/.claude/settings.json` 里有 `mcp__plugin_telegram_telegram__*` |
| typing 不持续显示 | patch 没生效 | 运行 `grep activeTyping ~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts` |
| 配对写到了错误目录 | skills 没 patch | 重新运行 `bash install.sh` |
| 两个 bot 冲突 | 用了相同名字 | 确认用不同名字：`launch.sh 1` vs `launch.sh 2` |
| 插件更新后全部失效 | marketplace 覆盖了 | 重新 `bash install.sh`，launch.sh 每次启动也会自动 patch |
