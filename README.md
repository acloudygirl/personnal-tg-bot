# cloudy_lesbian_bot（Rust + Telegram）

这是一个使用 Rust（`teloxide`）开发的 Telegram 机器人项目，目标账号为 `@cloudy_lesbian_bot`。

## 命令说明

- `/start`：欢迎信息
- `/help`：命令列表
- `/ping`：连通性检测
- `/chatid`：显示当前聊天 ID
- `/whoami`：显示当前机器人用户名
- `/daily HH:MM @username message`：新增每日定时 @ 提醒
- `/dailies`：查看当前群的定时任务
- `/dailydel <id>`：删除指定任务

## 每日提醒行为

任务触发时，机器人会发送：

`@目标用户 @发起人想要和你说：<自定义消息>`

## 运行方式

1. 在 `@BotFather` 创建机器人并获取 Token
2. 复制环境变量模板：

   ```powershell
   Copy-Item .env.example .env
   ```

3. 编辑 `.env`：
   - `TELOXIDE_TOKEN=...`
   - `TELOXIDE_PROXY=...`（如果你的网络环境无法直连 Telegram）
4. 启动：

   ```powershell
   cargo run
   ```

## 持久化

- 每日任务保存在项目根目录的 `schedules.db`
- 机器人启动时会自动加载已有任务

## 后台运行与开机自启
- 有些问题都是因为我沟槽的大学（某双一流）晚上断网断电后才发现的，真谢谢你啊（）
- 安装开机自启（登录触发）：

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\install-autostart.ps1
  ```

- 立即后台启动（代理 + 机器人）：

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\start-stack.ps1
  ```

- 停止（代理 + 机器人）：

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\stop-stack.ps1
  ```

- 查看代理健康摘要：

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\proxy-health-report.ps1
  ```

`start-stack.ps1` 还会自动启动以下守护能力：

- keep-awake：降低合盖后 Modern Standby 导致的暂停风险
- proxy watchdog：自动切换到健康代理组
- bot watchdog：连续网络失败时自动重启机器人

## 机器人独立代理（不受日常 VPN 开关影响）

如果你希望机器人始终走独立代理核心（即使你平时 VPN 客户端关闭），可在 `.env` 配置：

```env
TELOXIDE_PROXY=http://127.0.0.1:17890
BOT_PROXY_EXE=C:\path\to\mihomo.exe
BOT_PROXY_ARGS=-f C:\path\to\config.yaml
BOT_PROXY_WORKDIR=C:\path\to
BOT_PROXY_CONTROLLER=http://127.0.0.1:19097
BOT_PROXY_SECRET=set-your-secret
BOT_PROXY_PRIMARY_GROUP=LiltPupu  ( •̀ᴗ•́ )✧
```

- `start-stack.ps1` 会先同步代理配置，再依次启动 keep-awake、代理核心、代理守护、机器人守护和机器人主程序
- 机器人启动前会短暂等待代理端口可用
