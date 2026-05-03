use std::fs::{File, OpenOptions};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{Days, Local, NaiveDate, NaiveTime};
use fs2::FileExt;
use log::{info, warn};
use rusqlite::{Connection, params};
use teloxide::prelude::*;
use teloxide::types::{Me, User};
use teloxide::utils::command::BotCommands;
use tokio::sync::Mutex;
use tokio::time::{self, Duration, MissedTickBehavior};

const EXPECTED_BOT_USERNAME: &str = "cloudy_lesbian_bot";
const DB_FILE_PATH: &str = "schedules.db";
const LOCK_FILE_PATH: &str = "cloudy_lesbian_bot.lock";

type SharedSchedules = Arc<Mutex<ScheduleStore>>;

struct SingleInstanceLock {
    _file: File,
}

#[derive(Debug)]
struct ScheduleStore {
    db_path: PathBuf,
    schedules: Vec<DailyMentionSchedule>,
}

#[derive(Debug, Clone)]
struct DailyMentionSchedule {
    id: u64,
    chat_id: ChatId,
    trigger_time: NaiveTime,
    next_fire_date: NaiveDate,
    creator_mention: String,
    target_mention: String,
    message: String,
}

#[derive(Debug, Clone)]
struct OutboundMessage {
    schedule_id: u64,
    chat_id: ChatId,
    text: String,
}

#[derive(BotCommands, Clone)]
#[command(rename_rule = "lowercase", description = "可用命令：")]
enum Command {
    #[command(description = "启动机器人")]
    Start,
    #[command(description = "查看帮助")]
    Help,
    #[command(description = "在线检测")]
    Ping,
    #[command(description = "查看当前聊天 ID")]
    Chatid,
    #[command(description = "查看当前机器人用户名")]
    Whoami,
    #[command(description = "新增每日任务：/daily HH:MM @用户名 消息")]
    Daily(String),
    #[command(description = "查看本群每日任务")]
    Dailies,
    #[command(description = "删除任务：/dailydel 任务ID")]
    Dailydel(String),
}

#[tokio::main]
async fn main() {
    dotenvy::dotenv().ok();
    pretty_env_logger::init();
    info!("Booting @{} ...", EXPECTED_BOT_USERNAME);

    let _instance_lock = match try_acquire_single_instance_lock() {
        Ok(Some(lock)) => lock,
        Ok(None) => {
            warn!("Another bot instance is already running. This process will exit.");
            return;
        }
        Err(err) => {
            warn!("Failed to acquire single-instance lock: {err}");
            return;
        }
    };

    let bot = Bot::from_env();
    let store = ScheduleStore::load_or_init(DB_FILE_PATH)
        .unwrap_or_else(|err| panic!("Failed to initialize schedule storage: {err}"));
    let schedules = Arc::new(Mutex::new(store));

    let me = wait_for_telegram_api(&bot).await;

    if let Err(err) = setup_commands_and_check_identity(&bot, &me).await {
        warn!("Cannot set bot commands or verify bot identity: {err}");
    }

    let scheduler_bot = bot.clone();
    let scheduler_state = schedules.clone();
    tokio::spawn(async move {
        run_scheduler(scheduler_bot, scheduler_state).await;
    });

    Command::repl(bot, move |bot: Bot, msg: Message, cmd: Command| {
        let schedules = schedules.clone();
        async move { answer(bot, msg, cmd, schedules).await }
    })
    .await;
}

fn try_acquire_single_instance_lock() -> std::io::Result<Option<SingleInstanceLock>> {
    let file = OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(LOCK_FILE_PATH)?;

    match file.try_lock_exclusive() {
        Ok(()) => Ok(Some(SingleInstanceLock { _file: file })),
        Err(err) if err.kind() == ErrorKind::WouldBlock => Ok(None),
        Err(err) => Err(err),
    }
}

async fn wait_for_telegram_api(bot: &Bot) -> Me {
    let mut attempts = 0_u64;

    loop {
        attempts += 1;
        match bot.get_me().await {
            Ok(me) => {
                info!("Telegram API reachable after {} attempt(s).", attempts);
                return me;
            }
            Err(err) => {
                warn!(
                    "Telegram API not reachable (attempt {}): {}. Retrying in 5s...",
                    attempts, err
                );
                time::sleep(Duration::from_secs(5)).await;
            }
        }
    }
}

async fn setup_commands_and_check_identity(bot: &Bot, me: &Me) -> ResponseResult<()> {
    if me.user.username.as_deref() != Some(EXPECTED_BOT_USERNAME) {
        warn!(
            "Connected bot is @{:?}, expected @{}",
            me.user.username, EXPECTED_BOT_USERNAME
        );
    } else {
        info!("Connected as @{}", EXPECTED_BOT_USERNAME);
    }

    bot.set_my_commands(Command::bot_commands()).await?;
    Ok(())
}

async fn answer(
    bot: Bot,
    msg: Message,
    cmd: Command,
    schedules: SharedSchedules,
) -> ResponseResult<()> {
    match cmd {
        Command::Start => {
            bot.send_message(
                msg.chat.id,
                format!(
                    "你好，我是 @{}。\n发送 /help 可以查看命令列表。",
                    EXPECTED_BOT_USERNAME
                ),
            )
            .await?;
        }
        Command::Help => {
            bot.send_message(msg.chat.id, Command::descriptions().to_string())
                .await?;
        }
        Command::Ping => {
            bot.send_message(msg.chat.id, "pong ✅").await?;
        }
        Command::Chatid => {
            bot.send_message(msg.chat.id, format!("当前 chat id: {}", msg.chat.id))
                .await?;
        }
        Command::Whoami => {
            bot.send_message(
                msg.chat.id,
                format!("当前机器人用户名：@{}", EXPECTED_BOT_USERNAME),
            )
            .await?;
        }
        Command::Daily(args) => {
            handle_daily_create(&bot, &msg, &args, schedules).await?;
        }
        Command::Dailies => {
            handle_daily_list(&bot, &msg, schedules).await?;
        }
        Command::Dailydel(args) => {
            handle_daily_delete(&bot, &msg, &args, schedules).await?;
        }
    }

    Ok(())
}

async fn handle_daily_create(
    bot: &Bot,
    msg: &Message,
    args: &str,
    schedules: SharedSchedules,
) -> ResponseResult<()> {
    if !msg.chat.is_group() && !msg.chat.is_supergroup() {
        bot.send_message(msg.chat.id, "这个命令只能在群聊里使用。")
            .await?;
        return Ok(());
    }

    let Some(from) = msg.from.as_ref() else {
        bot.send_message(msg.chat.id, "无法识别这条消息的发送者。")
            .await?;
        return Ok(());
    };

    let (trigger_time, target_mention, custom_message) = match parse_daily_args(args) {
        Ok(data) => data,
        Err(err) => {
            bot.send_message(
                msg.chat.id,
                format!(
                    "{}\n用法：/daily HH:MM @用户名 消息内容\n示例：/daily 09:30 @alice 早安",
                    err
                ),
            )
            .await?;
            return Ok(());
        }
    };

    let now = Local::now();
    let today = now.date_naive();
    let next_fire_date = if now.time() < trigger_time {
        today
    } else {
        today.checked_add_days(Days::new(1)).unwrap_or(today)
    };
    let creator_mention = creator_mention(from);

    let id = {
        let mut state = schedules.lock().await;
        match state.insert_schedule(
            msg.chat.id,
            trigger_time,
            next_fire_date,
            creator_mention.clone(),
            target_mention.clone(),
            custom_message.clone(),
        ) {
            Ok(id) => id,
            Err(err) => {
                warn!("Failed to save daily task: {err}");
                bot.send_message(msg.chat.id, "保存每日任务失败，请稍后再试。")
                    .await?;
                return Ok(());
            }
        }
    };

    bot.send_message(
        msg.chat.id,
        format!(
            "每日任务已创建。\nID: {}\n时间: {}\n目标: {}\n下次执行日期: {}\n消息: {}",
            id,
            trigger_time.format("%H:%M"),
            target_mention,
            next_fire_date,
            custom_message
        ),
    )
    .await?;

    Ok(())
}

async fn handle_daily_list(
    bot: &Bot,
    msg: &Message,
    schedules: SharedSchedules,
) -> ResponseResult<()> {
    if !msg.chat.is_group() && !msg.chat.is_supergroup() {
        bot.send_message(msg.chat.id, "这个命令只能在群聊里使用。")
            .await?;
        return Ok(());
    }

    let state = schedules.lock().await;
    let lines: Vec<String> = state
        .schedules
        .iter()
        .filter(|item| item.chat_id == msg.chat.id)
        .map(|item| {
            format!(
                "ID {} | {} | {} | 下次 {}",
                item.id,
                item.trigger_time.format("%H:%M"),
                item.target_mention,
                item.next_fire_date
            )
        })
        .collect();

    if lines.is_empty() {
        bot.send_message(msg.chat.id, "本群还没有每日任务。")
            .await?;
    } else {
        let text = format!("本群每日任务：\n{}", lines.join("\n"));
        bot.send_message(msg.chat.id, text).await?;
    }

    Ok(())
}

async fn handle_daily_delete(
    bot: &Bot,
    msg: &Message,
    args: &str,
    schedules: SharedSchedules,
) -> ResponseResult<()> {
    if !msg.chat.is_group() && !msg.chat.is_supergroup() {
        bot.send_message(msg.chat.id, "这个命令只能在群聊里使用。")
            .await?;
        return Ok(());
    }

    let id = match args.trim().parse::<u64>() {
        Ok(id) => id,
        Err(_) => {
            bot.send_message(msg.chat.id, "用法：/dailydel <任务ID>\n示例：/dailydel 1")
                .await?;
            return Ok(());
        }
    };

    let removed = {
        let mut state = schedules.lock().await;
        match state.delete_schedule(msg.chat.id, id) {
            Ok(removed) => removed,
            Err(err) => {
                warn!("Failed to delete daily task {id}: {err}");
                bot.send_message(msg.chat.id, "删除任务失败，请稍后再试。")
                    .await?;
                return Ok(());
            }
        }
    };

    if removed {
        bot.send_message(msg.chat.id, format!("已删除任务 {}。", id))
            .await?;
    } else {
        bot.send_message(msg.chat.id, format!("本群未找到任务 {}。", id))
            .await?;
    }

    Ok(())
}

fn parse_daily_args(args: &str) -> Result<(NaiveTime, String, String), String> {
    let mut parts = args.split_whitespace();

    let Some(time_str) = parts.next() else {
        return Err("缺少时间参数。".to_string());
    };
    let trigger_time = NaiveTime::parse_from_str(time_str, "%H:%M")
        .map_err(|_| "时间格式错误，请使用 HH:MM（24 小时制），如 09:30。".to_string())?;

    let Some(target) = parts.next() else {
        return Err("缺少目标用户名参数。".to_string());
    };
    if !target.starts_with('@') || target.len() < 2 {
        return Err("目标必须是 Telegram @用户名。".to_string());
    }

    let message_words: Vec<&str> = parts.collect();
    if message_words.is_empty() {
        return Err("缺少消息内容。".to_string());
    }
    let message = message_words.join(" ");

    Ok((trigger_time, target.to_string(), message))
}

fn creator_mention(user: &User) -> String {
    user.mention()
        .unwrap_or_else(|| format!("@{}", user.first_name.replace(' ', "_")))
}

async fn run_scheduler(bot: Bot, schedules: SharedSchedules) {
    let mut ticker = time::interval(Duration::from_secs(20));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Delay);

    loop {
        ticker.tick().await;
        let due_messages = collect_due_messages(&schedules).await;

        for item in due_messages {
            if let Err(err) = bot.send_message(item.chat_id, item.text).await {
                warn!(
                    "Failed to send scheduled message for task {}: {}",
                    item.schedule_id, err
                );
            }
        }
    }
}

async fn collect_due_messages(schedules: &SharedSchedules) -> Vec<OutboundMessage> {
    let now = Local::now();
    let today = now.date_naive();
    let current_time = now.time();

    let mut due_messages = Vec::new();
    let mut updates = Vec::new();
    let mut state = schedules.lock().await;

    for schedule in &mut state.schedules {
        let should_fire = schedule.next_fire_date < today
            || (schedule.next_fire_date == today && current_time >= schedule.trigger_time);

        if should_fire {
            schedule.next_fire_date = today.checked_add_days(Days::new(1)).unwrap_or(today);
            updates.push((schedule.id, schedule.next_fire_date));
            due_messages.push(OutboundMessage {
                schedule_id: schedule.id,
                chat_id: schedule.chat_id,
                text: format!(
                    "{} {}想要和你说：{}",
                    schedule.target_mention, schedule.creator_mention, schedule.message
                ),
            });
        }
    }

    if let Err(err) = state.persist_next_fire_dates(&updates) {
        warn!("Failed to persist schedule ticks: {err}");
    }

    due_messages
}

impl ScheduleStore {
    fn load_or_init(
        db_path: impl AsRef<Path>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let db_path = db_path.as_ref().to_path_buf();
        let conn = Connection::open(&db_path)?;
        Self::ensure_schema(&conn)?;

        let mut stmt = conn.prepare(
            "SELECT id, chat_id, trigger_time, next_fire_date, creator_mention, target_mention, message
             FROM daily_schedules
             ORDER BY id",
        )?;

        let schedules = stmt
            .query_map([], |row| {
                let id: i64 = row.get(0)?;
                let chat_id: i64 = row.get(1)?;
                let trigger_time_raw: String = row.get(2)?;
                let next_fire_date_raw: String = row.get(3)?;
                let trigger_time =
                    NaiveTime::parse_from_str(&trigger_time_raw, "%H:%M").map_err(|err| {
                        rusqlite::Error::FromSqlConversionFailure(
                            2,
                            rusqlite::types::Type::Text,
                            Box::new(err),
                        )
                    })?;
                let next_fire_date = NaiveDate::parse_from_str(&next_fire_date_raw, "%Y-%m-%d")
                    .map_err(|err| {
                        rusqlite::Error::FromSqlConversionFailure(
                            3,
                            rusqlite::types::Type::Text,
                            Box::new(err),
                        )
                    })?;

                Ok(DailyMentionSchedule {
                    id: id as u64,
                    chat_id: ChatId(chat_id),
                    trigger_time,
                    next_fire_date,
                    creator_mention: row.get(4)?,
                    target_mention: row.get(5)?,
                    message: row.get(6)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;

        info!(
            "Loaded {} daily schedule(s) from {}",
            schedules.len(),
            DB_FILE_PATH
        );

        Ok(Self { db_path, schedules })
    }

    fn ensure_schema(conn: &Connection) -> rusqlite::Result<()> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS daily_schedules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id INTEGER NOT NULL,
                trigger_time TEXT NOT NULL,
                next_fire_date TEXT NOT NULL,
                creator_mention TEXT NOT NULL,
                target_mention TEXT NOT NULL,
                message TEXT NOT NULL
            );",
        )?;
        Ok(())
    }

    fn open_conn(&self) -> rusqlite::Result<Connection> {
        let conn = Connection::open(&self.db_path)?;
        Self::ensure_schema(&conn)?;
        Ok(conn)
    }

    fn insert_schedule(
        &mut self,
        chat_id: ChatId,
        trigger_time: NaiveTime,
        next_fire_date: NaiveDate,
        creator_mention: String,
        target_mention: String,
        message: String,
    ) -> rusqlite::Result<u64> {
        let conn = self.open_conn()?;
        conn.execute(
            "INSERT INTO daily_schedules (
                chat_id, trigger_time, next_fire_date, creator_mention, target_mention, message
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                chat_id.0,
                trigger_time.format("%H:%M").to_string(),
                next_fire_date.format("%Y-%m-%d").to_string(),
                creator_mention,
                target_mention,
                message
            ],
        )?;
        let id = conn.last_insert_rowid() as u64;

        self.schedules.push(DailyMentionSchedule {
            id,
            chat_id,
            trigger_time,
            next_fire_date,
            creator_mention,
            target_mention,
            message,
        });

        Ok(id)
    }

    fn delete_schedule(&mut self, chat_id: ChatId, id: u64) -> rusqlite::Result<bool> {
        let conn = self.open_conn()?;
        let affected = conn.execute(
            "DELETE FROM daily_schedules WHERE id = ?1 AND chat_id = ?2",
            params![id as i64, chat_id.0],
        )?;

        if affected > 0 {
            self.schedules
                .retain(|item| !(item.id == id && item.chat_id == chat_id));
            Ok(true)
        } else {
            Ok(false)
        }
    }

    fn persist_next_fire_dates(&self, updates: &[(u64, NaiveDate)]) -> rusqlite::Result<()> {
        if updates.is_empty() {
            return Ok(());
        }

        let mut conn = self.open_conn()?;
        let tx = conn.transaction()?;
        for (id, next_fire_date) in updates {
            tx.execute(
                "UPDATE daily_schedules SET next_fire_date = ?1 WHERE id = ?2",
                params![next_fire_date.format("%Y-%m-%d").to_string(), *id as i64],
            )?;
        }
        tx.commit()?;
        Ok(())
    }
}
