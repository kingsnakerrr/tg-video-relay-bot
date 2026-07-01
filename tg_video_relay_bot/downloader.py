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
        "http_headers": {
            "User-Agent": (
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/126.0.0.0 Safari/537.36"
            ),
            "Referer": "https://x.com/",
        },
    }
    if settings.cookies_file and settings.cookies_file.exists():
        options["cookiefile"] = str(settings.cookies_file)

    try:
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(url, download=True)
    except Exception as exc:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise DownloadError(str(exc)) from exc

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
