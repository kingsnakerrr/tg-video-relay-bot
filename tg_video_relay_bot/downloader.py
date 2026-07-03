from __future__ import annotations

import shutil
import uuid
from pathlib import Path

import yt_dlp

from .config import Settings
from .cookie_sync import CookieSyncError, sync_cookies_if_needed


TEMP_SUFFIXES = (".part", ".ytdl", ".temp", ".tmp")


class DownloadError(RuntimeError):
    pass


def _url_kind(url: str) -> str:
    lowered = url.lower()
    if "youtube.com" in lowered or "youtu.be" in lowered:
        return "youtube"
    if "tiktok.com" in lowered:
        return "tiktok"
    if "douyin.com" in lowered or "iesdouyin.com" in lowered:
        return "douyin"
    if "x.com" in lowered or "twitter.com" in lowered or "video.twimg.com" in lowered:
        return "twitter"
    return "generic"


def _headers_for(url: str) -> dict[str, str]:
    kind = _url_kind(url)
    referers = {
        "youtube": "https://www.youtube.com/",
        "tiktok": "https://www.tiktok.com/",
        "douyin": "https://www.douyin.com/",
        "twitter": "https://x.com/",
    }
    return {
        "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/126.0.0.0 Safari/537.36"
        ),
        "Accept-Language": "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7",
        "Referer": referers.get(kind, "https://www.google.com/"),
    }


def _friendly_download_error(url: str, message: str) -> str:
    kind = _url_kind(url)
    lowered = message.lower()
    if "http error 403" in lowered or "forbidden" in lowered:
        if kind == "youtube":
            return (
                "YouTube returned HTTP 403 Forbidden. This is usually caused by an old yt-dlp, "
                "VPS IP risk checks, or missing YouTube cookies. Run `x ytdlp-update` first. "
                "If it still fails, export YouTube cookies in Netscape cookies.txt format, put them "
                "into COOKIES_FILE, then run `x cookies` and `x restart`."
            )
        if kind == "tiktok":
            return (
                "TikTok returned HTTP 403 Forbidden. Run `x ytdlp-update` first. If it still fails, "
                "use TikTok cookies in COOKIES_FILE or try from another VPS IP/region."
            )
    return message


def _media_files(directory: Path) -> list[Path]:
    files: list[Path] = []
    for path in directory.iterdir():
        if not path.is_file():
            continue
        if any(path.name.endswith(suffix) for suffix in TEMP_SUFFIXES):
            continue
        files.append(path)
    return files


def download_video(url: str, settings: Settings) -> tuple[Path, str]:
    settings.download_dir.mkdir(parents=True, exist_ok=True)
    job_dir = settings.download_dir / uuid.uuid4().hex
    job_dir.mkdir(parents=True, exist_ok=False)

    try:
        sync_cookies_if_needed(settings)
    except CookieSyncError as exc:
        if not (settings.cookies_file and settings.cookies_file.exists()):
            shutil.rmtree(job_dir, ignore_errors=True)
            raise DownloadError(str(exc)) from exc

    options: dict[str, object] = {
        "format": settings.download_format,
        "outtmpl": str(job_dir / "%(title).180B [%(id)s].%(ext)s"),
        "merge_output_format": settings.merge_output_format,
        "noplaylist": True,
        "restrictfilenames": True,
        "quiet": True,
        "no_warnings": True,
        "max_filesize": settings.max_file_bytes,
        "concurrent_fragment_downloads": 4,
        "fragment_retries": 10,
        "retries": 5,
        "extractor_retries": 5,
        "file_access_retries": 5,
        "socket_timeout": 30,
        "geo_bypass": True,
        "http_headers": _headers_for(url),
    }
    if settings.ytdlp_force_ipv4:
        options["source_address"] = "0.0.0.0"
    if settings.ytdlp_http_chunk_size > 0:
        options["http_chunk_size"] = settings.ytdlp_http_chunk_size
    if settings.youtube_player_clients:
        options["extractor_args"] = {
            "youtube": {"player_client": settings.youtube_player_clients},
        }
    if settings.cookies_file and settings.cookies_file.exists():
        options["cookiefile"] = str(settings.cookies_file)

    try:
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(url, download=True)
    except Exception as exc:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise DownloadError(_friendly_download_error(url, str(exc))) from exc

    info = info or {}

    files = _media_files(job_dir)
    if not files:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise DownloadError("Download finished, but no media file was produced.")

    file_path = max(files, key=lambda item: item.stat().st_size)
    title = str(info.get("title") or file_path.stem)
    return file_path, title


def cleanup_download(file_path: Path) -> None:
    parent = file_path.parent
    if parent.exists():
        shutil.rmtree(parent, ignore_errors=True)
