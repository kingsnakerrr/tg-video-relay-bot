from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def load_dotenv(path: Path) -> None:
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def _split_csv(value: str) -> list[str]:
    return [item.strip() for item in value.split(",") if item.strip()]


def _parse_chat_ids(value: str) -> list[int | str]:
    chats: list[int | str] = []
    for item in _split_csv(value):
        if item.startswith("@"):
            chats.append(item)
            continue
        try:
            chats.append(int(item))
        except ValueError as exc:
            raise ValueError(f"Invalid TARGET_CHAT_IDS entry: {item}") from exc
    return chats


def _parse_user_ids(value: str) -> set[int]:
    users: set[int] = set()
    for item in _split_csv(value):
        try:
            users.add(int(item))
        except ValueError as exc:
            raise ValueError(f"Invalid ALLOWED_USER_IDS entry: {item}") from exc
    return users


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None or value == "":
        return default
    return value.lower() in {"1", "true", "yes", "y", "on"}


def _env_int(name: str, default: int) -> int:
    value = os.getenv(name)
    if value is None or value == "":
        return default
    return int(value)


@dataclass(frozen=True)
class Settings:
    bot_token: str
    target_chat_ids: list[int | str]
    allowed_user_ids: set[int]
    download_dir: Path
    download_format: str
    merge_output_format: str
    max_file_mb: int
    max_upload_mb: int
    auto_compress: bool
    compress_audio_kbps: int
    cookies_file: Path | None
    cookie_sync_url: str
    cookie_sync_interval_minutes: int
    upload_mode: str
    delete_after_all_uploads: bool
    bot_api_timeout: int
    upload_timeout: int
    poll_timeout: int
    worker_count: int

    @property
    def max_file_bytes(self) -> int:
        return self.max_file_mb * 1024 * 1024

    @property
    def max_upload_bytes(self) -> int:
        return self.max_upload_mb * 1024 * 1024


def load_settings() -> Settings:
    load_dotenv(Path(".env"))

    bot_token = os.getenv("BOT_TOKEN", "").strip()
    if not bot_token or bot_token == "123456789:replace_me":
        raise ValueError("BOT_TOKEN is required. Copy .env.example to .env and fill it in.")

    target_chat_ids = _parse_chat_ids(os.getenv("TARGET_CHAT_IDS", ""))
    if not target_chat_ids:
        raise ValueError("TARGET_CHAT_IDS is required. Add at least one channel or group.")

    upload_mode = os.getenv("UPLOAD_MODE", "video").strip().lower()
    if upload_mode not in {"video", "document"}:
        raise ValueError("UPLOAD_MODE must be video or document.")

    cookies_value = os.getenv("COOKIES_FILE", "").strip()
    cookies_file = Path(cookies_value).expanduser() if cookies_value else None

    return Settings(
        bot_token=bot_token,
        target_chat_ids=target_chat_ids,
        allowed_user_ids=_parse_user_ids(os.getenv("ALLOWED_USER_IDS", "")),
        download_dir=Path(os.getenv("DOWNLOAD_DIR", "downloads")).expanduser(),
        download_format=os.getenv("DOWNLOAD_FORMAT", "bv*+ba/best"),
        merge_output_format=os.getenv("MERGE_OUTPUT_FORMAT", "mp4"),
        max_file_mb=_env_int("MAX_FILE_MB", 1900),
        max_upload_mb=_env_int("MAX_UPLOAD_MB", 49),
        auto_compress=_env_bool("AUTO_COMPRESS", True),
        compress_audio_kbps=_env_int("COMPRESS_AUDIO_KBPS", 96),
        cookies_file=cookies_file,
        cookie_sync_url=os.getenv("COOKIE_SYNC_URL", "").strip(),
        cookie_sync_interval_minutes=max(1, _env_int("COOKIE_SYNC_INTERVAL_MINUTES", 360)),
        upload_mode=upload_mode,
        delete_after_all_uploads=_env_bool("DELETE_AFTER_ALL_UPLOADS", True),
        bot_api_timeout=_env_int("BOT_API_TIMEOUT", 30),
        upload_timeout=_env_int("UPLOAD_TIMEOUT", 1800),
        poll_timeout=_env_int("POLL_TIMEOUT", 50),
        worker_count=max(1, _env_int("WORKER_COUNT", 1)),
    )
