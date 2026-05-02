# cloudy_lesbian_bot (Rust + Telegram)

A Telegram bot built with Rust (`teloxide`) for `@cloudy_lesbian_bot`.

## 命令

- `/start` - 欢迎
- `/help` - 帮助列表
- `/ping` - 测试连接
- `/chatid` - 当前聊天id
- `/whoami` - 我 是 谁.jpg
- `/daily HH:MM @username message` - 定时骚扰指定群友
- `/dailies` - 当前骚扰任务
- `/dailydel <id>` - 删除任务

## 日常骚扰

如果你通过人力无法走进群友的心，可以定期骚扰

`@target @initiator想要和你说：<custom message>`

## 运行 (Run)

1. 通过 @BotFather 获得 token
2. 复制环境模板：

   ```powershell
   Copy-Item .env.example .env
   ```

3. 填写 `.env`：
   - `TELOXIDE_TOKEN=...`
   - `TELOXIDE_PROXY=...` (如果你的网络环境拦截了 Telegram.api的请求)
4. 启动：

   ```powershell
   cargo run
   ```

## 持久化 (Persistence)

- 每日任务存储在项目根目录下的 `schedules.db` 中。
- 启动时会自动加载现有任务。

## 后台运行 + 开机自启 (Background + Autostart)

- 安装自启动（登录触发）：

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\install-autostart.ps1
  ```

- 立即在后台启动代理 + 机器人：

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\start-stack.ps1
  ```

- 停止代理 + 机器人：

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\stop-stack.ps1
  ```

- 显示代理健康状态摘要（当前模式、选定分组、最优健康节点、近期自动切换计数）(鉴于最近机场不稳定，自动寻找最优解点)：

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\proxy-health-report.ps1
  ```

## 机器人专用代理（独立于 VPN 软件开关）

如果你希望机器人流量始终通过其独立的代理内核（即使你平时的 VPN 软件处于关闭状态），请将以下内容添加到 `.env`：
```env
TELOXIDE_PROXY=socks5h://127.0.0.1:7895
BOT_PROXY_EXE=C:\path\to\mihomo.exe
BOT_PROXY_ARGS=-f C:\path\to\config.yaml
BOT_PROXY_WORKDIR=C:\path\to
```

- `start-stack.ps1` 会先启动代理内核，然后再启动机器人。
- 机器人启动前会简短地等待代理端口就绪。
- 后台运行一个代理守护进程，会自动持续切换到健康的节点组。
```
