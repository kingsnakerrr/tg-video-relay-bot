from __future__ import annotations

import json
import logging
import time
from pathlib import Path
from typing import Any

import requests

from .media_info import probe_video_info


class TelegramApiError(RuntimeError):
    pass


LOGGER = logging.getLogger(__name__)


class TelegramApi:
    def __init__(
        self,
        token: str,
        timeout: int,
        upload_timeout: int,
        *,
        base_url: str = "https://api.telegram.org",
        use_local_file_uri: bool = False,
        retries: int = 3,
    ) -> None:
        self.base_url = f"{base_url.rstrip('/')}/bot{token}"
        self.timeout = timeout
        self.upload_timeout = upload_timeout
        self.use_local_file_uri = use_local_file_uri
        self.retries = max(1, retries)

    def _request(
        self,
        method: str,
        *,
        data: dict[str, Any] | None = None,
        files: dict[str, Any] | None = None,
        timeout: int | None = None,
    ) -> dict[str, Any]:
        response: requests.Response | None = None
        last_error: Exception | None = None
        for attempt in range(1, self.retries + 1):
            if files:
                for item in files.values():
                    handle = item[1] if isinstance(item, tuple) and len(item) >= 2 else item
                    if hasattr(handle, "seek"):
                        handle.seek(0)
            try:
                response = requests.post(
                    f"{self.base_url}/{method}",
                    data=data,
                    files=files,
                    timeout=timeout or self.timeout,
                )
                if response.status_code < 500:
                    break
                last_error = TelegramApiError(f"{method} HTTP {response.status_code}")
            except requests.RequestException as exc:
                last_error = exc

            if attempt < self.retries:
                wait_seconds = min(2 * attempt, 10)
                LOGGER.warning(
                    "Telegram API request failed, retrying: method=%s attempt=%s/%s error=%s",
                    method,
                    attempt,
                    self.retries,
                    last_error,
                )
                time.sleep(wait_seconds)

        if response is None:
            raise TelegramApiError(f"{method} failed after {self.retries} attempts: {last_error}")
        if response.status_code == 413:
            raise TelegramApiError(
                f"{method} failed: file is too large for Telegram Bot API. "
                "With the public Bot API, keep MAX_UPLOAD_MB=49 and AUTO_COMPRESS=true. "
                "For original-quality large uploads, use a local Telegram Bot API server, "
                "set BOT_API_BASE_URL to it, set BOT_API_USE_LOCAL_FILE_URI=true, "
                "then set AUTO_COMPRESS=false."
            )
        try:
            payload = response.json()
        except ValueError as exc:
            raise TelegramApiError(f"{method} returned non-JSON HTTP {response.status_code}") from exc

        if not payload.get("ok"):
            description = payload.get("description", "unknown Telegram API error")
            raise TelegramApiError(f"{method} failed: {description}")
        return payload

    def get_updates(self, offset: int | None, timeout: int) -> list[dict[str, Any]]:
        data: dict[str, Any] = {
            "timeout": timeout,
            "allowed_updates": '["message","channel_post","callback_query"]',
        }
        if offset is not None:
            data["offset"] = offset
        payload = self._request("getUpdates", data=data, timeout=timeout + self.timeout)
        return list(payload.get("result", []))

    def send_message(
        self,
        chat_id: int | str,
        text: str,
        *,
        reply_to_message_id: int | None = None,
        reply_markup: dict[str, Any] | None = None,
    ) -> None:
        data: dict[str, Any] = {
            "chat_id": chat_id,
            "text": text,
            "disable_web_page_preview": True,
        }
        if reply_to_message_id is not None:
            data["reply_to_message_id"] = reply_to_message_id
            data["allow_sending_without_reply"] = True
        if reply_markup is not None:
            data["reply_markup"] = json.dumps(reply_markup, ensure_ascii=False)
        self._request("sendMessage", data=data)

    def edit_message_text(
        self,
        chat_id: int | str,
        message_id: int,
        text: str,
        *,
        reply_markup: dict[str, Any] | None = None,
    ) -> None:
        data: dict[str, Any] = {
            "chat_id": chat_id,
            "message_id": message_id,
            "text": text,
            "disable_web_page_preview": True,
        }
        if reply_markup is not None:
            data["reply_markup"] = json.dumps(reply_markup, ensure_ascii=False)
        self._request("editMessageText", data=data)

    def answer_callback_query(
        self,
        callback_query_id: str,
        text: str = "",
        *,
        show_alert: bool = False,
    ) -> None:
        data: dict[str, Any] = {
            "callback_query_id": callback_query_id,
            "show_alert": "true" if show_alert else "false",
        }
        if text:
            data["text"] = text
        self._request("answerCallbackQuery", data=data)

    def send_video(
        self,
        chat_id: int | str,
        file_path: Path,
        *,
        caption: str,
    ) -> None:
        data = {
            "chat_id": chat_id,
            "caption": caption,
            "supports_streaming": True,
        }
        info = probe_video_info(file_path)
        if info:
            data["width"], data["height"] = info.width, info.height
        if self.use_local_file_uri:
            data["video"] = file_path.resolve().as_uri()
            self._request("sendVideo", data=data, timeout=self.upload_timeout)
            return
        with file_path.open("rb") as handle:
            self._request(
                "sendVideo",
                data=data,
                files={"video": (file_path.name, handle)},
                timeout=self.upload_timeout,
            )

    def send_document(
        self,
        chat_id: int | str,
        file_path: Path,
        *,
        caption: str,
    ) -> None:
        data = {"chat_id": chat_id, "caption": caption}
        if self.use_local_file_uri:
            data["document"] = file_path.resolve().as_uri()
            self._request("sendDocument", data=data, timeout=self.upload_timeout)
            return
        with file_path.open("rb") as handle:
            self._request(
                "sendDocument",
                data=data,
                files={"document": (file_path.name, handle)},
                timeout=self.upload_timeout,
            )
