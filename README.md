# Telegram Typing Heartbeat Plugin for Claude Code

Claude Code 官方 Telegram Channel 插件的增强版，解决 typing 指示器 5 秒消失的问题。

## 改了什么

官方插件在收到消息时只发一次 `sendChatAction("typing")`，5 秒后过期。本插件添加了 3 秒心跳循环，在 Claude 处理任务期间持续显示 typing 状态。

### 具体改动（相对官方 server.ts）

1. **bot.use() 中间件**：每条消息进来时启动 3 秒 `setInterval` 心跳
2. **reply 工具 handler**：发送回复前 `clearInterval` 停止心跳
3. **安全超时**：10 分钟后自动清除心跳（防止泄漏）
4. **权限配置**：`mcp__plugin_telegram_telegram__*` 自动允许所有工具调用

## 前置条件

- macOS / Linux
- Node.js (>= 18)
- Claude Code (>= v2.1.80)，已登录 claude.ai 账号

## 安装

### 第一步：安装官方 Telegram 插件

在 Claude Code session 里执行：

```
/plugin install telegram@claude-plugins-official
/reload-plugins
```

退出 session（Ctrl+C 或 /exit）。

### 第二步：运行安装脚本

```bash
git clone https://github.com/casillas-qf/claude-channel-typing.git
cd claude-channel-typing
bash install.sh
```

这会自动完成：patch typing 心跳、配置权限（不再弹确认框）、生成启动脚本。

### 第三步：添加 bot

```bash
bash install.sh --add-bot <名字> <TOKEN>
```

例如：
```bash
bash install.sh --add-bot work 123456789:AAH...
bash install.sh --add-bot personal 987654321:BBX...
```

### 第四步（可选）：一键生成 alias + 安装自动重启

```bash
bash install.sh --setup-aliases    # 扫描已有 bots，自动写入 bashrc/zshrc
bash install.sh --install-runner   # 安装 bot-runner.sh（带自动重启）
```

或者用 `--full-setup` 一步到位（适合新机器）：

```bash
bash install.sh --full-setup
```

## 日常使用

### 启动 bot

```bash
bash ~/.claude/plugins/custom/telegram-typing/launch.sh <名字>
```

### 首次配对（每个 bot 只需一次）

1. 启动后，去 Telegram DM 你的 bot
2. Bot 回复 6 位配对码
3. 在 Claude Code session 里输入：`/telegram:access pair <配对码>`
4. 锁定：`/telegram:access policy allowlist`

### 同时跑多个 bot

```bash
# 终端 1
bash ~/.claude/plugins/custom/telegram-typing/launch.sh work

# 终端 2
bash ~/.claude/plugins/custom/telegram-typing/launch.sh personal
```

### 自动生成 alias

```bash
bash install.sh --setup-aliases
```

自动扫描 `~/.claude/channels/telegram-*/`，为每个 bot 生成 `claude-<name>` alias 并写入 bashrc/zshrc。

### 带自动重启的 bot-runner

安装后在 tmux 里运行，崩溃自动重启：

```bash
bash install.sh --install-runner

# 然后：
tmux new-session -d -s bot-work 'bash ~/.claude/bot-manager/bot-runner.sh work'
```

## Bot Token 获取

1. 打开 Telegram，搜索 `@BotFather`
2. 发送 `/newbot`
3. 输入 bot 名称和 username
4. 复制 token（格式：`123456789:AAH...`）

## 文件结构

```
安装后：

~/.claude/plugins/custom/telegram-typing/
├── server.ts       # 带 typing 心跳的 MCP server
├── launch.sh       # 启动脚本
└── skills/
    ├── access/SKILL.md      # 配对/权限管理
    └── configure/SKILL.md   # token 配置

~/.claude/channels/
├── telegram-work/      ← bot 1 的状态
│   ├── .env
│   ├── access.json
│   └── inbox/
└── telegram-personal/  ← bot 2 的状态
    ├── .env
    ├── access.json
    └── inbox/
```

## 多 Agent 群聊讨论系统

支持多个 bot 在 Telegram 群里协作讨论和执行任务。

### 角色配置

| 角色 | 类型 | 行为 |
|------|------|------|
| 西神·主持（orchestrator） | moderator | 响应群里所有用户消息，不需要 @mention |
| 西神·工程师（engineer） | expert | 只在被 @mention 时响应，其余消息作为上下文 |
| 西神·产品前端（product） | expert | 同上，延迟 60s 响应（等其他人先说） |
| 西神·批判者（critic） | expert | 同上，延迟 90s 响应 |

### 快速开始

```bash
# 1. 配置 bot token（交互式）
bash setup-discussion-group.sh --tokens

# 2. 创建 Telegram 群，把所有 bot 拉进去

# 3. 配置群组 ID
bash setup-discussion-group.sh --group-id -100XXXXXXXXXX

# 4. 启动所有 bot
bash setup-discussion-group.sh --start

# 5. 在每个 bot 的 CLI 里配对
#    /telegram:access pair <code>
#    /telegram:access policy allowlist
```

### 工作流程

```
你在群里发消息 → 主持人拆解课题 → @各专家分配任务
→ 专家依次响应（有延迟，不会撞车）
→ 专家之间可以互相 @辩论
→ 主持人汇总结论
→ 确认后可进入执行模式（各自在 git 分支开发）
```

### access.json 群组配置示例

```json
{
  "groups": {
    "-100123456789": {
      "requireMention": false,
      "allowFrom": [],
      "role": "moderator"
    }
  }
}
```

expert 角色配置：
```json
{
  "groups": {
    "-100123456789": {
      "requireMention": true,
      "allowFrom": [],
      "role": "expert",
      "discussionDelay": 30
    }
  }
}
```

## 故障排查

| 问题 | 原因 | 解决 |
|------|------|------|
| bot 不回复配对码 | token 没写入或 server 没启动 | 确认用 `launch.sh` 启动 |
| reply 每次要点确认 | 权限没配好 | 检查 `~/.claude/settings.json` 里有 `mcp__plugin_telegram_telegram__*` |
| typing 不持续显示 | patch 没生效 | 运行 `grep activeTyping ~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts` |
| 两个 bot 冲突 | 用了相同名字 | 确认用不同名字 |
| 插件更新后失效 | marketplace 覆盖了 | 重新 `bash install.sh`，launch.sh 每次启动也会自动 patch |
