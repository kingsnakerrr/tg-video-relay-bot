from __future__ import annotations

import logging
import secrets
import time
from dataclasses import dataclass
from typing import Any

from .config import Settings, load_settings
from .downloader import DownloadError, probe_resolutions
from .formats import DEFAULT_DOWNLOAD_FORMAT, DEFAULT_MAX_HEIGHT
from .jobs import JobQueue, VideoJob
from .links import extract_urls
from .submit_server import SubmitServerError, start_submit_server
from .telegram_api import TelegramApi, TelegramApiError


LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"
RESOLUTION_CALLBACK_PREFIX = "res"
PENDING_SELECTION_TTL_SECONDS = 30 * 60


@dataclass(frozen=True)
class PendingResolutionSelection:
    url: str
    source_chat_id: int | str
    source_message_id: int | None
    source_user_id: int | None
    title: str
    choices: dict[str, tuple[str, str]]
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
) -> None:
    position = job_queue.enqueue(
        VideoJob(
            source_chat_id=chat_id,
            source_message_id=message_id,
            source_user_id=user_id,
            url=url,
            download_format=settings.download_format or DEFAULT_DOWNLOAD_FORMAT,
            resolution_label="默认 1080p / 最高可用",
        )
    )
    text = f"已按默认 1080p 加入队列：{url}\n当前排队：{position}"
    if reason:
        text = f"{reason}\n{text}"
    api.send_message(chat_id, text, reply_to_message_id=message_id)


def _send_resolution_menu(
    api: TelegramApi,
    settings: Settings,
    job_queue: JobQueue,
    pending: dict[str, PendingResolutionSelection],
    chat_id: int | str,
    message_id: int | None,
    user_id: int | None,
    url: str,
) -> None:
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
            reason=f"获取清晰度失败，先按默认 1080p 下载：{exc}",
        )
        return

    token = secrets.token_urlsafe(8)
    default_label = "默认 1080p"
    default_choice = next(
        (choice for choice in probe.choices if probe.default_height and choice.height == probe.default_height),
        None,
    )
    if probe.default_height and probe.default_height < DEFAULT_MAX_HEIGHT:
        default_label = f"默认 1080p（最高 {default_choice.label if default_choice else f'{probe.default_height}p'}）"
    elif default_choice:
        default_label = f"默认 1080p（{default_choice.label}）"

    choices: dict[str, tuple[str, str]] = {
        "auto": (settings.download_format or DEFAULT_DOWNLOAD_FORMAT, default_label),
    }
    for choice in probe.choices:
        choices[str(choice.height)] = (choice.format_selector, choice.label)

    keyboard: list[list[dict[str, str]]] = [
        [{"text": default_label, "callback_data": _callback_data(token, "auto")}],
    ]
    row: list[dict[str, str]] = []
    for choice in probe.choices:
        row.append({"text": choice.label, "callback_data": _callback_data(token, str(choice.height))})
        if len(row) == 2:
            keyboard.append(row)
            row = []
    if row:
        keyboard.append(row)

    pending[token] = PendingResolutionSelection(
        url=url,
        source_chat_id=chat_id,
        source_message_id=message_id,
        source_user_id=user_id,
        title=probe.title,
        choices=choices,
        created_at=time.time(),
    )

    title = _short_text(probe.title)
    api.send_message(
        chat_id,
        "请选择下载清晰度：\n"
        f"{title}\n\n"
        "默认会选最高 1080p；如果源视频低于 1080p，就自动选最高可用。大小是 yt-dlp 估算值。",
        reply_to_message_id=message_id,
        reply_markup={"inline_keyboard": keyboard},
    )


def _handle_resolution_callback(
    api: TelegramApi,
    settings: Settings,
    job_queue: JobQueue,
    pending: dict[str, PendingResolutionSelection],
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
    _cleanup_pending_selections(pending)
    selection = pending.get(token)
    if selection is None:
        api.answer_callback_query(callback_id, "这个选择已过期，请重新发送链接。", show_alert=True)
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
    pending.pop(token, None)
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
                f"已选择：{label}\n已加入队列：{selection.url}\n当前排队：{position}",
            )
        except TelegramApiError:
            api.send_message(
                selection.source_chat_id,
                f"已选择：{label}\n已加入队列：{selection.url}\n当前排队：{position}",
                reply_to_message_id=selection.source_message_id,
            )
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
        api.send_message(
            chat_id,
            "发给我 X/Twitter、TikTok、抖音或 YouTube 链接，我会下载后转发到配置好的频道/群组。",
            reply_to_message_id=message_id,
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
            f"当前排队任务：{job_queue.pending_count()}",
            reply_to_message_id=message_id,
        )
        return True

    return False


def _handle_message(
    api: TelegramApi,
    settings: Settings,
    job_queue: JobQueue,
    pending: dict[str, PendingResolutionSelection],
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
            _send_resolution_menu(api, settings, job_queue, pending, chat_id, message_id, user_id, url)
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
    )
    job_queue = JobQueue(api, settings)
    job_queue.start()
    pending_resolution_selections: dict[str, PendingResolutionSelection] = {}

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
                if callback_query and _handle_resolution_callback(
                    api,
                    settings,
                    job_queue,
                    pending_resolution_selections,
                    callback_query,
                ):
                    continue
                message = _message_from_update(update)
                if message:
                    _handle_message(api, settings, job_queue, pending_resolution_selections, message)
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
