use std::collections::HashSet;
use std::fs::{File, OpenOptions, create_dir_all};
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{Days, Duration as ChronoDuration, Local, NaiveDate, NaiveTime};
use fs2::FileExt;
use log::{info, warn};
use rusqlite::ErrorCode;
use rusqlite::{Connection, params};
use teloxide::prelude::*;
use teloxide::types::{Me, User};
use teloxide::utils::command::BotCommands;
use tokio::sync::{Mutex, OnceCell};
use tokio::time::{self, Duration, MissedTickBehavior};

// 固定机器人用户名，用于启动后身份校验
const EXPECTED_BOT_USERNAME: &str = "cloudy_lesbian_bot";
// SQLite 数据库文件名
const DB_FILE_PATH: &str = "schedules.db";
// 单实例锁文件名，防止同一台机器误启动多个 bot 进程
const LOCK_FILE_PATH: &str = "cloudy_lesbian_bot.lock";
// 运行时目录名（存放锁文件等），默认位于 LOCALAPPDATA 下
const RUNTIME_DIR_NAME: &str = "cloudy_lesbian_bot";
// 消息发送窗口（分钟）：超过窗口的任务视为过期，不补发
const SEND_WINDOW_MINUTES: i64 = 10;
// 任务键对应的唯一索引名。
const UNIQUE_RULE_INDEX: &str = "idx_daily_schedules_unique_rule";

// 用于进程内“只打印一次”的日志开关，避免日志刷屏。
static UNIQUE_INDEX_WARNED: OnceCell<()> = OnceCell::const_new();

// 共享内存状态
type SharedSchedules = Arc<Mutex<ScheduleStore>>;

// 单实例锁句柄；只要该结构存活，文件锁就保持占用
struct SingleInstanceLock {
    _files: Vec<File>,
}

#[derive(Debug)]
// 调度存储：内存缓存 + 数据库路径
struct ScheduleStore {
    db_path: PathBuf,
    schedules: Vec<DailyMentionSchedule>,
}

#[derive(Debug, Clone)]
// 每日提醒任务
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
// 待发送消息
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
    #[command(description = "新增骚扰群友任务：/daily HH:MM @用户名 消息")]
    Daily(String),
    #[command(description = "查看本群被骚扰的群友")]
    Dailies,
    #[command(description = "删除任务：/dailydel 骚扰任务ID")]
    Dailydel(String),
}

//初始化环境、校验单实例、拉起调度器并启动命令处理循环
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

// 尝试获取进程级文件锁，确保机器人单实例运行
fn try_acquire_single_instance_lock() -> std::io::Result<Option<SingleInstanceLock>> {
    let runtime_lock_path = runtime_file_path(LOCK_FILE_PATH)?;
    let legacy_lock_path = PathBuf::from(LOCK_FILE_PATH);
    let lock_paths = if runtime_lock_path == legacy_lock_path {
        vec![runtime_lock_path]
    } else {
        vec![runtime_lock_path, legacy_lock_path]
    };

    let mut files = Vec::new();
    for path in lock_paths {
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(path)?;

        match file.try_lock_exclusive() {
            Ok(()) => files.push(file),
            Err(err) if err.kind() == ErrorKind::WouldBlock => return Ok(None),
            Err(err) => return Err(err),
        }
    }

    Ok(Some(SingleInstanceLock { _files: files }))
}

// 构建运行时文件路径，并确保父目录存在。
fn runtime_file_path(file_name: &str) -> std::io::Result<PathBuf> {
    let base_dir = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let runtime_dir = base_dir.join(RUNTIME_DIR_NAME);
    create_dir_all(&runtime_dir)?;
    Ok(runtime_dir.join(file_name))
}

// 启动时循环探测 Telegram API，直到可连接为止。
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

// 设置机器人命令菜单并校验当前 token 对应的 bot 身份。
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

// 统一命令分发入口。
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

// 创建每日任务：参数校验、重复检测、写入数据库并反馈结果。
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

    // 计算首次触发日期：今天时刻未到则今天触发，否则从明天开始。
    let now = Local::now();
    let today = now.date_naive();
    let next_fire_date = if now.time() < trigger_time {
        today
    } else {
        today.checked_add_days(Days::new(1)).unwrap_or(today)
    };
    let creator_mention = creator_mention(from);

    let mut duplicate_tip: Option<String> = None;
    let mut create_error = false;
    // 在持锁状态下执行“重复检测 + 入库”保证一致性。
    let id = {
        let mut state = schedules.lock().await;
        if let Some(existing) = state.schedules.iter().find(|item| {
            item.chat_id == msg.chat.id
                && item.trigger_time == trigger_time
                && item.creator_mention == creator_mention
                && item.target_mention == target_mention
                && item.message == custom_message
        }) {
            duplicate_tip = Some(format!(
                "检测到相同任务已存在。\nID: {}\n时间: {}\n目标: {}\n下次执行日期: {}\n消息: {}",
                existing.id,
                existing.trigger_time.format("%H:%M"),
                existing.target_mention,
                existing.next_fire_date,
                existing.message
            ));
            0
        } else {
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
                    if is_unique_violation(&err) {
                        if let Some(existing) = state.schedules.iter().find(|item| {
                            item.chat_id == msg.chat.id
                                && item.trigger_time == trigger_time
                                && item.creator_mention == creator_mention
                                && item.target_mention == target_mention
                                && item.message == custom_message
                        }) {
                            duplicate_tip = Some(format!(
                                "检测到相同任务已存在。\nID: {}\n时间: {}\n目标: {}\n下次执行日期: {}\n消息: {}",
                                existing.id,
                                existing.trigger_time.format("%H:%M"),
                                existing.target_mention,
                                existing.next_fire_date,
                                existing.message
                            ));
                            0
                        } else {
                            warn!("Unique constraint hit but no in-memory duplicate found: {err}");
                            create_error = true;
                            0
                        }
                    } else {
                        warn!("Failed to save daily task: {err}");
                        create_error = true;
                        0
                    }
                }
            }
        }
    };

    if create_error {
        bot.send_message(msg.chat.id, "保存每日任务失败，请稍后再试。")
            .await?;
        return Ok(());
    }

    if let Some(text) = duplicate_tip {
        bot.send_message(msg.chat.id, text).await?;
        return Ok(());
    }

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

// 列出当前群的所有每日任务。
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

// 删除当前群指定任务 ID。
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

// 解析 /daily 参数：HH:MM @目标 用户消息。
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

// 生成“发起人提及文本”，优先 @username，退化到 first_name。
fn creator_mention(user: &User) -> String {
    user.mention()
        .unwrap_or_else(|| format!("@{}", user.first_name.replace(' ', "_")))
}

// 调度循环：固定间隔扫描到期任务并发送。
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

// 计算本轮待发送消息：处理过期策略、窗口策略、原子更新和去重。
async fn collect_due_messages(schedules: &SharedSchedules) -> Vec<OutboundMessage> {
    let now = Local::now();
    let today = now.date_naive();
    let current_time = now.time();
    let send_window = ChronoDuration::minutes(SEND_WINDOW_MINUTES);
    let now_naive = now.naive_local();

    let mut due_messages = Vec::new();
    let mut sent_schedule_ids = HashSet::new();
    let mut sent_message_keys = HashSet::new();
    let mut state = schedules.lock().await;
    let conn = match state.open_conn() {
        Ok(conn) => conn,
        Err(err) => {
            warn!("Failed to open sqlite when collecting due messages: {err}");
            return due_messages;
        }
    };

    for schedule in &mut state.schedules {
        // bot 离线导致日期落后：仅推进 next_fire_date，不补发历史消息。
        if schedule.next_fire_date < today {
            let trigger_at_today = schedule.next_fire_date.and_time(schedule.trigger_time);
            let since_trigger = now_naive.signed_duration_since(trigger_at_today);
            let next_date = if since_trigger < send_window {
                today
            } else {
                today.checked_add_days(Days::new(1)).unwrap_or(today)
            };
            if persist_next_fire_date_if_matches(
                &conn,
                schedule.id,
                schedule.next_fire_date,
                next_date,
            ) {
                schedule.next_fire_date = next_date;
            }
            continue;
        }

        if schedule.next_fire_date == today && current_time >= schedule.trigger_time {
            let trigger_at_today = schedule.next_fire_date.and_time(schedule.trigger_time);
            let since_trigger = now_naive.signed_duration_since(trigger_at_today);
            let next_date = today.checked_add_days(Days::new(1)).unwrap_or(today);
            // 超出窗口期：今天这次视为过期，直接推进到下一次。
            if since_trigger >= send_window {
                if persist_next_fire_date_if_matches(
                    &conn,
                    schedule.id,
                    schedule.next_fire_date,
                    next_date,
                ) {
                    schedule.next_fire_date = next_date;
                }
                continue;
            }

            // 原子更新成功才允许发送，防止并发下重复触发。
            if !persist_next_fire_date_if_matches(
                &conn,
                schedule.id,
                schedule.next_fire_date,
                next_date,
            ) {
                continue;
            }

            schedule.next_fire_date = next_date;
            // 先按任务 ID 去重，再按消息签名去重，双保险防止重复发送。
            if !sent_schedule_ids.insert(schedule.id) {
                continue;
            }
            let dedupe_key = format!(
                "{}|{}|{}|{}|{}",
                schedule.chat_id.0,
                schedule.trigger_time.format("%H:%M"),
                schedule.creator_mention,
                schedule.target_mention,
                schedule.message
            );
            if !sent_message_keys.insert(dedupe_key) {
                continue;
            }

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

    due_messages
}

fn is_unique_violation(err: &rusqlite::Error) -> bool {
    match err {
        rusqlite::Error::SqliteFailure(sqlite_err, msg) => {
            sqlite_err.code == ErrorCode::ConstraintViolation
                || msg
                    .as_ref()
                    .map(|text| text.contains(UNIQUE_RULE_INDEX))
                    .unwrap_or(false)
        }
        _ => false,
    }
}

// CAS 风格更新 next_fire_date：只有 old_date 匹配时才更新，成功返回 true。
fn persist_next_fire_date_if_matches(
    conn: &Connection,
    schedule_id: u64,
    old_date: NaiveDate,
    next_date: NaiveDate,
) -> bool {
    let changed = match conn.execute(
        "UPDATE daily_schedules
         SET next_fire_date = ?1
         WHERE id = ?2 AND next_fire_date = ?3",
        params![
            next_date.format("%Y-%m-%d").to_string(),
            schedule_id as i64,
            old_date.format("%Y-%m-%d").to_string()
        ],
    ) {
        Ok(changed) => changed,
        Err(err) => {
            warn!(
                "Failed to persist next_fire_date for task {}: {}",
                schedule_id, err
            );
            return false;
        }
    };
    changed > 0
}

impl ScheduleStore {
    // 启动时加载数据库；不存在则自动建表。
    fn load_or_init(
        db_path: impl AsRef<Path>,
    ) -> Result<Self, Box<dyn std::error::Error + Send + Sync>> {
        let db_path = db_path.as_ref().to_path_buf();
        let conn = Connection::open(&db_path)?;
        Self::ensure_schema(&conn)?;
        let removed = Self::deduplicate_existing_schedules(&conn)?;
        if removed > 0 {
            warn!(
                "Removed {} duplicate daily schedule(s) while normalizing database.",
                removed
            );
        }
        if let Err(err) = Self::ensure_unique_index(&conn) {
            if UNIQUE_INDEX_WARNED.get().is_none() {
                if err.to_string().contains(UNIQUE_RULE_INDEX) {
                    warn!(
                        "Skip creating unique index {} due to existing duplicates conflict: {}",
                        UNIQUE_RULE_INDEX, err
                    );
                } else {
                    warn!(
                        "Failed to ensure unique index {}: {}",
                        UNIQUE_RULE_INDEX, err
                    );
                }
                let _ = UNIQUE_INDEX_WARNED.set(());
            }
        }

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

    // 确保 daily_schedules 表存在。
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

    // 清理历史重复任务：保留同一业务键最早的一条记录。
    fn deduplicate_existing_schedules(conn: &Connection) -> rusqlite::Result<usize> {
        conn.execute(
            "DELETE FROM daily_schedules
             WHERE id NOT IN (
                 SELECT MIN(id)
                 FROM daily_schedules
                 GROUP BY chat_id, trigger_time, creator_mention, target_mention, message
             )",
            [],
        )
    }

    // 用唯一索引兜底，防止重复任务再次落库。
    fn ensure_unique_index(conn: &Connection) -> rusqlite::Result<()> {
        conn.execute_batch(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_daily_schedules_unique_rule
             ON daily_schedules (chat_id, trigger_time, creator_mention, target_mention, message);",
        )?;
        Ok(())
    }

    // 每次操作独立打开连接，避免长期连接状态不一致。
    fn open_conn(&self) -> rusqlite::Result<Connection> {
        let conn = Connection::open(&self.db_path)?;
        Self::ensure_schema(&conn)?;
        Ok(conn)
    }

    // 新增任务：先写库，再同步内存缓存。
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

    // 删除任务：按 chat_id + id 限定，避免跨群误删。
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
}
