# cloudy_lesbian_bot (Rust + Telegram)

A Telegram bot built with Rust (`teloxide`) for `@cloudy_lesbian_bot`.

## Commands

- `/start` - welcome message
- `/help` - command list
- `/ping` - health check
- `/chatid` - current chat id
- `/whoami` - configured bot username
- `/daily HH:MM @username message` - add a daily scheduled group mention
- `/dailies` - list daily tasks in current group
- `/dailydel <id>` - delete a daily task in current group

## Daily mention behavior

At schedule time, bot sends:

`@target @initiator想要和你说：<custom message>`

## Run

1. Create a bot in `@BotFather` and get token.
2. Copy env template:

   ```powershell
   Copy-Item .env.example .env
   ```

3. Fill `.env`:
   - `TELOXIDE_TOKEN=...`
   - `TELOXIDE_PROXY=...` (if Telegram is blocked on your network)
4. Start:

   ```powershell
   cargo run
   ```

## Persistence

- Daily tasks are stored in `schedules.db` in project root.
- Existing tasks are loaded automatically on startup.

## Background + Autostart

- Install autostart (logon trigger):

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\install-autostart.ps1
  ```

- Start proxy + bot now in background:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\start-stack.ps1
  ```

- Stop proxy + bot:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\stop-stack.ps1
  ```

- Show proxy health summary:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\scripts\proxy-health-report.ps1
  ```

- `start-stack.ps1` also starts:
  - keep-awake helper (reduce Modern Standby suspension when lid is closed)
  - proxy watchdog (auto switch to healthy proxy group)

## Dedicated proxy for bot (independent from your VPN app toggle)

If you want bot traffic always through its own proxy core (even when your normal VPN app is off), add these to `.env`:

```env
TELOXIDE_PROXY=http://127.0.0.1:17890
BOT_PROXY_EXE=C:\path\to\mihomo.exe
BOT_PROXY_ARGS=-f C:\path\to\config.yaml
BOT_PROXY_WORKDIR=C:\path\to
BOT_PROXY_CONTROLLER=http://127.0.0.1:19097
BOT_PROXY_SECRET=set-your-secret
BOT_PROXY_PRIMARY_GROUP=LiltPupu  ( •̀ᴗ•́ )✧
```

- `start-stack.ps1` first syncs proxy config, then starts keep-awake, proxy core, proxy watchdog, and bot.
- Bot startup waits for proxy endpoint briefly before launching.
