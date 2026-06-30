from __future__ import annotations

from pathlib import Path
from typing import Any

import requests


class TelegramApiError(RuntimeError):
    pass


class TelegramApi:
    def __init__(self, token: str, timeout: int, upload_timeout: int) -> None:
        self.base_url = f"https://api.telegram.org/bot{token}"
        self.timeout = timeout
        self.upload_timeout = upload_timeout

    def _request(
        self,
        method: str,
        *,
        data: dict[str, Any] | None = None,
        files: dict[str, Any] | None = None,
        timeout: int | None = None,
    ) -> dict[str, Any]:
        response = requests.post(
            f"{self.base_url}/{method}",
            data=data,
            files=files,
            timeout=timeout or self.timeout,
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
            "allowed_updates": '["message","channel_post"]',
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
    ) -> None:
        data: dict[str, Any] = {
            "chat_id": chat_id,
            "text": text,
            "disable_web_page_preview": True,
        }
        if reply_to_message_id is not None:
            data["reply_to_message_id"] = reply_to_message_id
            data["allow_sending_without_reply"] = True
        self._request("sendMessage", data=data)

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
        with file_path.open("rb") as handle:
            self._request(
                "sendDocument",
                data=data,
                files={"document": (file_path.name, handle)},
                timeout=self.upload_timeout,
            )
