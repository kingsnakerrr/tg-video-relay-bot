from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

from .formats import DEFAULT_DOWNLOAD_FORMAT


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
        os.environ[key] = value


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


def _parse_optional_chat_id(value: str) -> int | str | None:
    item = value.strip()
    if not item:
        return None
    if item.startswith("@"):
        return item
    try:
        return int(item)
    except ValueError as exc:
        raise ValueError(f"Invalid chat ID: {item}") from exc


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


def _env_size_bytes(name: str, default: int) -> int:
    value = os.getenv(name)
    if value is None or value.strip() == "":
        return default
    text = value.strip().lower()
    multiplier = 1
    if text.endswith("k"):
        multiplier = 1024
        text = text[:-1]
    elif text.endswith("m"):
        multiplier = 1024 * 1024
        text = text[:-1]
    elif text.endswith("g"):
        multiplier = 1024 * 1024 * 1024
        text = text[:-1]
    return int(float(text) * multiplier)


@dataclass(frozen=True)
class Settings:
    bot_token: str
    bot_api_base_url: str
    bot_api_use_local_file_uri: bool
    target_chat_ids: list[int | str]
    allowed_user_ids: set[int]
    download_dir: Path
    download_format: str
    merge_output_format: str
    max_file_mb: int
    max_upload_mb: int
    auto_compress: bool
    compress_audio_kbps: int
    compress_min_video_kbps: int
    ytdlp_force_ipv4: bool
    ytdlp_http_chunk_size: int
    youtube_player_clients: list[str]
    cookies_file: Path | None
    cookies_file_x: Path | None
    cookies_file_youtube: Path | None
    cookie_sync_url: str
    cookie_sync_url_x: str
    cookie_sync_url_youtube: str
    cookie_sync_interval_minutes: int
    submit_api_enabled: bool
    submit_api_host: str
    submit_api_port: int
    submit_api_secret: str
    submit_notify_chat_id: int | str | None
    upload_mode: str
    delete_after_all_uploads: bool
    bot_api_timeout: int
    upload_timeout: int
    upload_retries: int
    poll_timeout: int
    worker_count: int
    telegram_resolution_menu: bool
    telegram_resolution_auto_seconds: int

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
    cookies_x_value = os.getenv("COOKIES_FILE_X", "").strip()
    cookies_youtube_value = os.getenv("COOKIES_FILE_YOUTUBE", "").strip()
    cookies_file_x = Path(cookies_x_value).expanduser() if cookies_x_value else None
    cookies_file_youtube = Path(cookies_youtube_value).expanduser() if cookies_youtube_value else None

    allowed_user_ids = _parse_user_ids(os.getenv("ALLOWED_USER_IDS", ""))
    submit_notify_chat_id = _parse_optional_chat_id(os.getenv("SUBMIT_NOTIFY_CHAT_ID", ""))
    if submit_notify_chat_id is None and len(allowed_user_ids) == 1:
        submit_notify_chat_id = next(iter(allowed_user_ids))

    return Settings(
        bot_token=bot_token,
        bot_api_base_url=os.getenv("BOT_API_BASE_URL", "https://api.telegram.org").strip().rstrip("/"),
        bot_api_use_local_file_uri=_env_bool("BOT_API_USE_LOCAL_FILE_URI", False),
        target_chat_ids=target_chat_ids,
        allowed_user_ids=allowed_user_ids,
        download_dir=Path(os.getenv("DOWNLOAD_DIR", "downloads")).expanduser(),
        download_format=os.getenv("DOWNLOAD_FORMAT", DEFAULT_DOWNLOAD_FORMAT),
        merge_output_format=os.getenv("MERGE_OUTPUT_FORMAT", "mp4"),
        max_file_mb=_env_int("MAX_FILE_MB", 1900),
        max_upload_mb=_env_int("MAX_UPLOAD_MB", 49),
        auto_compress=_env_bool("AUTO_COMPRESS", True),
        compress_audio_kbps=_env_int("COMPRESS_AUDIO_KBPS", 96),
        compress_min_video_kbps=_env_int("COMPRESS_MIN_VIDEO_KBPS", 60),
        ytdlp_force_ipv4=_env_bool("YTDLP_FORCE_IPV4", True),
        ytdlp_http_chunk_size=_env_size_bytes("YTDLP_HTTP_CHUNK_SIZE", 10 * 1024 * 1024),
        youtube_player_clients=_split_csv(os.getenv("YOUTUBE_PLAYER_CLIENTS", "web,web_safari,ios,android")),
        cookies_file=cookies_file,
        cookies_file_x=cookies_file_x,
        cookies_file_youtube=cookies_file_youtube,
        cookie_sync_url=os.getenv("COOKIE_SYNC_URL", "").strip(),
        cookie_sync_url_x=os.getenv("COOKIE_SYNC_URL_X", "").strip(),
        cookie_sync_url_youtube=os.getenv("COOKIE_SYNC_URL_YOUTUBE", "").strip(),
        cookie_sync_interval_minutes=max(1, _env_int("COOKIE_SYNC_INTERVAL_MINUTES", 360)),
        submit_api_enabled=_env_bool("SUBMIT_API_ENABLED", True),
        submit_api_host=os.getenv("SUBMIT_API_HOST", "0.0.0.0").strip() or "0.0.0.0",
        submit_api_port=_env_int("SUBMIT_API_PORT", 8787),
        submit_api_secret=os.getenv("SUBMIT_API_SECRET", "").strip(),
        submit_notify_chat_id=submit_notify_chat_id,
        upload_mode=upload_mode,
        delete_after_all_uploads=_env_bool("DELETE_AFTER_ALL_UPLOADS", True),
        bot_api_timeout=_env_int("BOT_API_TIMEOUT", 30),
        upload_timeout=_env_int("UPLOAD_TIMEOUT", 1800),
        upload_retries=max(1, _env_int("UPLOAD_RETRIES", 3)),
        poll_timeout=_env_int("POLL_TIMEOUT", 50),
        worker_count=max(1, _env_int("WORKER_COUNT", 1)),
        telegram_resolution_menu=_env_bool("TELEGRAM_RESOLUTION_MENU", True),
        telegram_resolution_auto_seconds=max(0, _env_int("TELEGRAM_RESOLUTION_AUTO_SECONDS", 3)),
    )
