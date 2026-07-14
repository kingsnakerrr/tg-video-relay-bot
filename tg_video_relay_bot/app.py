from __future__ import annotations

import logging
import secrets
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from threading import Lock, Timer
from typing import Any

from .config import Settings, load_settings
from .downloader import DownloadError, probe_resolutions
from .formats import DEFAULT_DOWNLOAD_FORMAT, SAFE_FALLBACK_DOWNLOAD_FORMAT
from .jobs import JobQueue, VideoJob
from .links import extract_urls
from .submit_server import SubmitServerError, start_submit_server
from .telegram_api import TelegramApi, TelegramApiError
from .version import APP_VERSION


LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"
RESOLUTION_CALLBACK_PREFIX = "res"
ADMIN_CALLBACK_PREFIX = "cmd"
PENDING_SELECTION_TTL_SECONDS = 30 * 60
SERVICE_NAME = "telegram-video-relay"
CONTROL_SCRIPT = Path("control.sh")


@dataclass(frozen=True)
class PendingResolutionSelection:
    url: str
    source_chat_id: int | str
    source_message_id: int | None
    source_user_id: int | None
    title: str
    choices: dict[str, tuple[str, str]]
    auto_choice_key: str
    created_at: float


def _message_from_update(update: dict[str, Any]) -> dict[str, Any] | None:
    return update.get("message") or update.get("channel_post")


def _callback_query_from_update(update: dict[str, Any]) -> dict[str, Any] | None:
    return update.get("callback_query")


def _message_text(message: dict[str, Any]) -> str:
    return str(message.get("text") or message.get("caption") or "")


def _chat_id(message: dict[str, Any]) -> int | str:
    return message["chat"]["id"]


def _user_id(message: dict[str, Any]) -> int | None:
    user = message.get("from")
    if not user:
        return None
    return int(user["id"])


def _is_allowed(settings: Settings, user_id: int | None) -> bool:
    if not settings.allowed_user_ids:
        return True
    return user_id in settings.allowed_user_ids


def _cleanup_pending_selections(pending: dict[str, PendingResolutionSelection]) -> None:
    now = time.time()
    expired = [
        token
        for token, selection in pending.items()
        if now - selection.created_at > PENDING_SELECTION_TTL_SECONDS
    ]
    for token in expired:
        pending.pop(token, None)


def _callback_data(token: str, choice_key: str) -> str:
    return f"{RESOLUTION_CALLBACK_PREFIX}:{token}:{choice_key}"


def _short_text(text: str, limit: int = 120) -> str:
    if len(text) <= limit:
        return text
    return f"{text[: limit - 1]}…"


def _admin_callback_data(action: str) -> str:
    return f"{ADMIN_CALLBACK_PREFIX}:{action}"


def _admin_keyboard() -> dict[str, Any]:
    return {
        "inline_keyboard": [
            [
                {"text": "状态", "callback_data": _admin_callback_data("status")},
                {"text": "最近日志", "callback_data": _admin_callback_data("logs")},
            ],
            [
                {"text": "同步 cookies", "callback_data": _admin_callback_data("cookies")},
                {"text": "更新 yt-dlp", "callback_data": _admin_callback_data("ytdlp")},
            ],
            [
                {"text": "更新项目", "callback_data": _admin_callback_data("update")},
                {"text": "重启机器人", "callback_data": _admin_callback_data("restart")},
            ],
            [
                {"text": "停止/暂停", "callback_data": _admin_callback_data("stop")},
                {"text": "帮助", "callback_data": _admin_callback_data("help")},
            ],
        ]
    }


def _run_command(args: list[str], *, timeout: int = 20) -> str:
    try:
        completed = subprocess.run(
            args,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            encoding="utf-8",
            errors="replace",
        )
    except Exception as exc:
        return f"命令执行失败：{exc}"
    output = "\n".join(part for part in (completed.stdout.strip(), completed.stderr.strip()) if part)
    if not output:
        output = f"exit={completed.returncode}"
    return _short_text(output, 3500)


def _run_control_background(action: str) -> None:
    script = CONTROL_SCRIPT.resolve()
    if script.exists():
        args = ["bash", str(script), action]
    else:
        args = ["systemctl", action, SERVICE_NAME]
    subprocess.Popen(
        args,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def _admin_help_text() -> str:
    return (
        f"Telegram Video Relay {APP_VERSION}\n\n"
        "管理员命令：\n"
        "/menu - 打开按钮菜单\n"
        "/help - 显示帮助和按钮\n"
        "/status - 查看队列和服务状态\n"
        "/logs - 最近日志\n"
        "/cookies - 手动同步 cookies\n"
        "/ytdlp - 更新 yt-dlp\n"
        "/update - 更新项目并重启\n"
        "/restart - 重启机器人\n"
        "/stop - 停止/暂停机器人\n"
        "/id - 查看你的用户 ID 和当前聊天 ID\n"
        "/targets - 查看转发目标数量\n\n"
        "停止后机器人无法在 TG 里接收 /start，启动请 SSH 执行：x start"
    )


def _admin_status_text(settings: Settings, job_queue: JobQueue) -> str:
    service_status = _run_command(["systemctl", "is-active", SERVICE_NAME], timeout=5).strip()
    upload_mode = "Local Bot API 原画质" if settings.bot_api_use_local_file_uri else "公网 Bot API"
    return (
        f"Telegram Video Relay {APP_VERSION}\n"
        f"服务状态：{service_status}\n"
        f"当前排队：{job_queue.pending_count()}\n"
        f"目标数量：{len(settings.target_chat_ids)}\n"
        f"上传模式：{upload_mode}\n"
        f"MAX_UPLOAD_MB={settings.max_upload_mb}\n"
        f"AUTO_COMPRESS={settings.auto_compress}\n"
        f"UPLOAD_RETRIES={settings.upload_retries}\n"
        f"X cookies：{settings.cookies_file_x or '未设置'}\n"
        f"YouTube cookies：{settings.cookies_file_youtube or '未设置'}"
        f"\nPornhub cookies：{settings.cookies_file_pornhub or '未设置'}"
    )


def _enqueue_default_job(
    api: TelegramApi,
    settings: Settings,
    job_queue: JobQueue,
    chat_id: int | str,
    message_id: int | None,
    user_id: int | None,
    url: str,
    *,
    reason: str | None = None,
    safe_fallback: bool = False,
) -> None:
    if safe_fallback:
        download_format = SAFE_FALLBACK_DOWNLOAD_FORMAT
        resolution_label = "自动可用格式 / 解析失败兜底"
        queued_text = "已按自动可用格式加入队列"
    else:
        download_format = settings.download_format or DEFAULT_DOWNLOAD_FORMAT
        resolution_label = "最高可用"
        queued_text = "已按最高可用加入队列"

    position = job_queue.enqueue(
        VideoJob(
            source_chat_id=chat_id,
            source_message_id=message_id,
            source_user_id=user_id,
            url=url,
            download_format=download_format,
            resolution_label=resolution_label,
        )
    )
    text = f"{queued_text}: {url}\n当前排队: {position}"
    if reason:
        text = f"{reason}\n{text}"
    api.send_message(chat_id, text, reply_to_message_id=message_id)


def _send_resolution_menu(
    api: TelegramApi,
    settings: Settings,
    job_queue: JobQueue,
    pending: dict[str, PendingResolutionSelection],
    pending_lock: Lock,
    chat_id: int | str,
    message_id: int | None,
    user_id: int | None,
    url: str,
) -> None:
    with pending_lock:
        _cleanup_pending_selections(pending)
    try:
        probe = probe_resolutions(url, settings)
    except DownloadError as exc:
        _enqueue_default_job(
            api,
            settings,
            job_queue,
            chat_id,
            message_id,
            user_id,
            url,
            reason=f"获取清晰度失败，先按自动可用格式下载: {exc}",
            safe_fallback=True,
        )
        return

    token = secrets.token_urlsafe(8)
    highest_choice = probe.choices[0] if probe.choices else None
    default_label = f"默认最高画质（{highest_choice.label}）" if highest_choice else "默认最高画质"
    default_format = highest_choice.format_selector if highest_choice else (settings.download_format or DEFAULT_DOWNLOAD_FORMAT)
    auto_choice_key = "auto"
    choices: dict[str, tuple[str, str]] = {
        auto_choice_key: (default_format, default_label),
    }
    for choice in probe.choices:
        choices[str(choice.height)] = (choice.format_selector, choice.label)

    keyboard: list[list[dict[str, str]]] = [
        [{"text": default_label, "callback_data": _callback_data(token, auto_choice_key)}],
    ]
    row: list[dict[str, str]] = []
    for choice in probe.choices:
        row.append({"text": choice.label, "callback_data": _callback_data(token, str(choice.height))})
        if len(row) == 2:
            keyboard.append(row)
            row = []
    if row:
        keyboard.append(row)
    keyboard.append([{"text": "取消下载", "callback_data": _callback_data(token, "cancel")}])

    with pending_lock:
        pending[token] = PendingResolutionSelection(
            url=url,
            source_chat_id=chat_id,
            source_message_id=message_id,
            source_user_id=user_id,
            title=probe.title,
            choices=choices,
            auto_choice_key=auto_choice_key,
            created_at=time.time(),
        )

    title = _short_text(probe.title)
    api.send_message(
        chat_id,
        "请选择下载清晰度:\n"
        f"{title}\n\n"
        f"{settings.telegram_resolution_auto_seconds} 秒内不选择，会自动下载最高画质。大小是 yt-dlp 估算值。",
        reply_to_message_id=message_id,
        reply_markup={"inline_keyboard": keyboard},
    )
    if settings.telegram_resolution_auto_seconds > 0:
        timer = Timer(
            settings.telegram_resolution_auto_seconds,
            _auto_enqueue_resolution,
            args=(api, job_queue, pending, pending_lock, token, settings.telegram_resolution_auto_seconds),
        )
        timer.daemon = True
        timer.start()


def _auto_enqueue_resolution(
    api: TelegramApi,
    job_queue: JobQueue,
    pending: dict[str, PendingResolutionSelection],
    pending_lock: Lock,
    token: str,
    auto_seconds: int,
) -> None:
    with pending_lock:
        selection = pending.pop(token, None)
    if selection is None:
        return

    choice = selection.choices.get(selection.auto_choice_key)
    if choice is None:
        return
    download_format, label = choice
    position = job_queue.enqueue(
        VideoJob(
            source_chat_id=selection.source_chat_id,
            source_message_id=selection.source_message_id,
            source_user_id=selection.source_user_id,
            url=selection.url,
            download_format=download_format,
            resolution_label=label,
        )
    )
    try:
        api.send_message(
            selection.source_chat_id,
            f"{auto_seconds} 秒未选择，已自动选择最高画质: {label}\n已加入队列: {selection.url}\n当前排队: {position}",
            reply_to_message_id=selection.source_message_id,
        )
    except TelegramApiError:
        logging.exception("Failed to notify auto resolution selection")


def _handle_resolution_callback(
    api: TelegramApi,
    settings: Settings,
    job_queue: JobQueue,
    pending: dict[str, PendingResolutionSelection],
    pending_lock: Lock,
    callback_query: dict[str, Any],
) -> bool:
    data = str(callback_query.get("data") or "")
    if not data.startswith(f"{RESOLUTION_CALLBACK_PREFIX}:"):
        return False

    callback_id = str(callback_query.get("id") or "")
    callback_user = callback_query.get("from") or {}
    user_id = int(callback_user["id"]) if callback_user.get("id") is not None else None

    if not _is_allowed(settings, user_id):
        api.answer_callback_query(callback_id, "你没有下载权限。", show_alert=True)
        return True

    parts = data.split(":", 2)
    if len(parts) != 3:
        api.answer_callback_query(callback_id, "按钮数据无效，请重新发送链接。", show_alert=True)
        return True

    _, token, choice_key = parts
    if choice_key == "cancel":
        with pending_lock:
            selection = pending.pop(token, None)
        if selection is None:
            api.answer_callback_query(callback_id, "这个选择已过期或已自动开始下载，请重新发送链接。", show_alert=True)
            return True
        api.answer_callback_query(callback_id, "已取消下载。")
        message = callback_query.get("message") or {}
        chat = message.get("chat") or {}
        callback_chat_id = chat.get("id")
        callback_message_id = message.get("message_id")
        if callback_chat_id is not None and callback_message_id is not None:
            try:
                api.edit_message_text(
                    callback_chat_id,
                    int(callback_message_id),
                    f"已取消下载: {selection.url}",
                )
            except TelegramApiError:
                api.send_message(
                    selection.source_chat_id,
                    f"已取消下载: {selection.url}",
                    reply_to_message_id=selection.source_message_id,
                )
        return True

    with pending_lock:
        _cleanup_pending_selections(pending)
        selection = pending.pop(token, None)
    if selection is None:
        api.answer_callback_query(callback_id, "这个选择已过期或已自动开始下载，请重新发送链接。", show_alert=True)
        return True

    choice = selection.choices.get(choice_key)
    if choice is None:
        api.answer_callback_query(callback_id, "这个清晰度不可用，请重新发送链接。", show_alert=True)
        return True

    download_format, label = choice
    position = job_queue.enqueue(
        VideoJob(
            source_chat_id=selection.source_chat_id,
            source_message_id=selection.source_message_id,
            source_user_id=selection.source_user_id,
            url=selection.url,
            download_format=download_format,
            resolution_label=label,
        )
    )
    api.answer_callback_query(callback_id, "已加入队列。")

    message = callback_query.get("message") or {}
    chat = message.get("chat") or {}
    callback_chat_id = chat.get("id")
    callback_message_id = message.get("message_id")
    if callback_chat_id is not None and callback_message_id is not None:
        try:
            api.edit_message_text(
                callback_chat_id,
                int(callback_message_id),
                f"已选择: {label}\n已加入队列: {selection.url}\n当前排队: {position}",
            )
            return True
        except TelegramApiError:
            pass
    api.send_message(
        selection.source_chat_id,
        f"已选择: {label}\n已加入队列: {selection.url}\n当前排队: {position}",
        reply_to_message_id=selection.source_message_id,
    )
    return True

def _handle_admin_callback(
    api: TelegramApi,
    settings: Settings,
    job_queue: JobQueue,
    callback_query: dict[str, Any],
) -> bool:
    data = str(callback_query.get("data") or "")
    if not data.startswith(f"{ADMIN_CALLBACK_PREFIX}:"):
        return False

    callback_id = str(callback_query.get("id") or "")
    callback_user = callback_query.get("from") or {}
    user_id = int(callback_user["id"]) if callback_user.get("id") is not None else None
    if not _is_allowed(settings, user_id):
        api.answer_callback_query(callback_id, "你没有管理权限。", show_alert=True)
        return True

    action = data.split(":", 1)[1]
    message = callback_query.get("message") or {}
    chat = message.get("chat") or {}
    chat_id = chat.get("id")
    message_id = message.get("message_id")

    def reply(text: str, *, menu: bool = False) -> None:
        if chat_id is None:
            return
        markup = _admin_keyboard() if menu else None
        if message_id is not None:
            try:
                api.edit_message_text(chat_id, int(message_id), text, reply_markup=markup)
                return
            except TelegramApiError:
                pass
        api.send_message(chat_id, text, reply_markup=markup)

    if action == "help":
        api.answer_callback_query(callback_id, "帮助")
        reply(_admin_help_text(), menu=True)
        return True
    if action == "status":
        api.answer_callback_query(callback_id, "状态")
        reply(_admin_status_text(settings, job_queue), menu=True)
        return True
    if action == "logs":
        api.answer_callback_query(callback_id, "最近日志")
        logs = _run_command(["journalctl", "-u", SERVICE_NAME, "-n", "60", "--no-pager"], timeout=10)
        reply(f"最近日志：\n{logs}", menu=True)
        return True
    if action == "cookies":
        api.answer_callback_query(callback_id, "开始同步 cookies")
        reply("已开始同步 cookies，完成后请看日志或再次点状态。", menu=True)
        _run_control_background("cookies")
        return True
    if action == "ytdlp":
        api.answer_callback_query(callback_id, "开始更新 yt-dlp")
        reply("已开始更新 yt-dlp，完成后机器人会重启。", menu=True)
        _run_control_background("ytdlp-update")
        return True
    if action == "update":
        api.answer_callback_query(callback_id, "开始更新项目")
        reply("已开始更新项目，完成后机器人会重启。", menu=True)
        _run_control_background("update")
        return True
    if action == "restart":
        api.answer_callback_query(callback_id, "正在重启")
        reply("正在重启机器人。")
        _run_control_background("restart")
        return True
    if action == "stop":
        api.answer_callback_query(callback_id, "正在停止")
        reply("正在停止/暂停机器人。停止后 TG 里不能再启动，请 SSH 执行：x start")
        _run_control_background("stop")
        return True

    api.answer_callback_query(callback_id, "未知操作。", show_alert=True)
    return True


def _handle_command(
    api: TelegramApi,
    settings: Settings,
    job_queue: JobQueue,
    message: dict[str, Any],
    text: str,
) -> bool:
    command = text.split(maxsplit=1)[0].split("@", 1)[0].lower()
    chat_id = _chat_id(message)
    message_id = message.get("message_id")
    user_id = _user_id(message)

    if command == "/start":
        if _is_allowed(settings, user_id):
            api.send_message(
                chat_id,
                "发给我 X/Twitter、TikTok、抖音或 YouTube 链接，我会下载后转发到配置好的频道/群组。\n\n管理员可点下面菜单操作。",
                reply_to_message_id=message_id,
                reply_markup=_admin_keyboard(),
            )
        else:
            api.send_message(
                chat_id,
                "发给我 X/Twitter、TikTok、抖音或 YouTube 链接，我会下载后转发到配置好的频道/群组。",
                reply_to_message_id=message_id,
            )
        return True

    if command in {"/help", "/menu"}:
        if not _is_allowed(settings, user_id):
            api.send_message(chat_id, "你没有管理权限。", reply_to_message_id=message_id)
            return True
        api.send_message(
            chat_id,
            _admin_help_text() if command == "/help" else _admin_status_text(settings, job_queue),
            reply_to_message_id=message_id,
            reply_markup=_admin_keyboard(),
        )
        return True

    if command == "/id":
        api.send_message(
            chat_id,
            f"你的用户 ID：{user_id}\n当前聊天 ID：{chat_id}",
            reply_to_message_id=message_id,
        )
        return True

    if command == "/targets":
        if not _is_allowed(settings, user_id):
            return True
        api.send_message(
            chat_id,
            f"已配置 {len(settings.target_chat_ids)} 个转发目标。",
            reply_to_message_id=message_id,
        )
        return True

    if command == "/status":
        if not _is_allowed(settings, user_id):
            return True
        api.send_message(
            chat_id,
            _admin_status_text(settings, job_queue),
            reply_to_message_id=message_id,
            reply_markup=_admin_keyboard(),
        )
        return True

    if command == "/logs":
        if not _is_allowed(settings, user_id):
            return True
        logs = _run_command(["journalctl", "-u", SERVICE_NAME, "-n", "60", "--no-pager"], timeout=10)
        api.send_message(chat_id, f"最近日志：\n{logs}", reply_to_message_id=message_id, reply_markup=_admin_keyboard())
        return True

    if command == "/cookies":
        if not _is_allowed(settings, user_id):
            return True
        api.send_message(chat_id, "已开始同步 cookies。", reply_to_message_id=message_id, reply_markup=_admin_keyboard())
        _run_control_background("cookies")
        return True

    if command == "/ytdlp":
        if not _is_allowed(settings, user_id):
            return True
        api.send_message(chat_id, "已开始更新 yt-dlp，完成后机器人会重启。", reply_to_message_id=message_id)
        _run_control_background("ytdlp-update")
        return True

    if command == "/update":
        if not _is_allowed(settings, user_id):
            return True
        api.send_message(chat_id, "已开始更新项目，完成后机器人会重启。", reply_to_message_id=message_id)
        _run_control_background("update")
        return True

    if command == "/restart":
        if not _is_allowed(settings, user_id):
            return True
        api.send_message(chat_id, "正在重启机器人。", reply_to_message_id=message_id)
        _run_control_background("restart")
        return True

    if command == "/stop":
        if not _is_allowed(settings, user_id):
            return True
        api.send_message(chat_id, "正在停止/暂停机器人。停止后 TG 里不能再启动，请 SSH 执行：x start", reply_to_message_id=message_id)
        _run_control_background("stop")
        return True

    return False


def _handle_message(
    api: TelegramApi,
    settings: Settings,
    job_queue: JobQueue,
    pending: dict[str, PendingResolutionSelection],
    pending_lock: Lock,
    message: dict[str, Any],
) -> None:
    text = _message_text(message)
    if not text:
        return

    if text.startswith("/") and _handle_command(api, settings, job_queue, message, text):
        return

    urls = extract_urls(text)
    if not urls:
        return

    chat_id = _chat_id(message)
    message_id = message.get("message_id")
    user_id = _user_id(message)

    if not _is_allowed(settings, user_id):
        api.send_message(chat_id, "你没有提交下载任务的权限。发送 /id 给管理员添加白名单。", reply_to_message_id=message_id)
        return

    for url in urls:
        if settings.telegram_resolution_menu:
            _send_resolution_menu(api, settings, job_queue, pending, pending_lock, chat_id, message_id, user_id, url)
            continue

        position = job_queue.enqueue(
            VideoJob(
                source_chat_id=chat_id,
                source_message_id=message_id,
                source_user_id=user_id,
                url=url,
            )
        )
        api.send_message(chat_id, f"已加入队列：{url}\n当前排队：{position}", reply_to_message_id=message_id)


def run_bot(settings: Settings) -> None:
    api = TelegramApi(
        settings.bot_token,
        settings.bot_api_timeout,
        settings.upload_timeout,
        base_url=settings.bot_api_base_url,
        use_local_file_uri=settings.bot_api_use_local_file_uri,
        retries=settings.upload_retries,
    )
    job_queue = JobQueue(api, settings)
    job_queue.start()
    pending_resolution_selections: dict[str, PendingResolutionSelection] = {}
    pending_resolution_lock = Lock()

    try:
        api.set_my_commands(
            [
                {"command": "menu", "description": "打开管理员按钮菜单"},
                {"command": "help", "description": "显示所有命令"},
                {"command": "status", "description": "查看状态"},
                {"command": "logs", "description": "查看最近日志"},
                {"command": "cookies", "description": "同步 cookies"},
                {"command": "ytdlp", "description": "更新 yt-dlp"},
                {"command": "update", "description": "更新项目并重启"},
                {"command": "restart", "description": "重启机器人"},
                {"command": "stop", "description": "停止/暂停机器人"},
                {"command": "id", "description": "查看用户和聊天 ID"},
                {"command": "targets", "description": "查看转发目标"},
            ]
        )
    except TelegramApiError as exc:
        logging.warning("Failed to set bot commands: %s", exc)

    if settings.submit_api_enabled:
        try:
            start_submit_server(settings, job_queue)
        except SubmitServerError as exc:
            logging.warning("Submit API disabled: %s", exc)
        except OSError as exc:
            logging.warning("Submit API failed to start: %s", exc)

    logging.info("Bot started with %s target chats", len(settings.target_chat_ids))
    offset: int | None = None

    while True:
        try:
            updates = api.get_updates(offset, timeout=settings.poll_timeout)
            for update in updates:
                offset = int(update["update_id"]) + 1
                callback_query = _callback_query_from_update(update)
                if callback_query and _handle_admin_callback(
                    api,
                    settings,
                    job_queue,
                    callback_query,
                ):
                    continue
                if callback_query and _handle_resolution_callback(
                    api,
                    settings,
                    job_queue,
                    pending_resolution_selections,
                    pending_resolution_lock,
                    callback_query,
                ):
                    continue
                message = _message_from_update(update)
                if message:
                    _handle_message(api, settings, job_queue, pending_resolution_selections, pending_resolution_lock, message)
        except TelegramApiError as exc:
            logging.warning("Telegram API error: %s", exc)
            time.sleep(5)
        except requests_exceptions() as exc:
            logging.warning("Network error: %s", exc)
            time.sleep(5)
        except Exception:
            logging.exception("Unexpected polling error")
            time.sleep(5)


def requests_exceptions() -> tuple[type[BaseException], ...]:
    import requests

    return (requests.RequestException,)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
    settings = load_settings()
    run_bot(settings)

