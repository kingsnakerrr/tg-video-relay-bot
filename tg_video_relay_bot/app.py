from __future__ import annotations

import logging
import time
from typing import Any

from .config import Settings, load_settings
from .jobs import JobQueue, VideoJob
from .links import extract_urls
from .submit_server import SubmitServerError, start_submit_server
from .telegram_api import TelegramApi, TelegramApiError


LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s: %(message)s"


def _message_from_update(update: dict[str, Any]) -> dict[str, Any] | None:
    return update.get("message") or update.get("channel_post")


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
                message = _message_from_update(update)
                if message:
                    _handle_message(api, settings, job_queue, message)
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
