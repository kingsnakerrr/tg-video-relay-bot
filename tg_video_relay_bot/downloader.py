from __future__ import annotations

import shutil
import uuid
from dataclasses import dataclass
from pathlib import Path

import yt_dlp

from .config import Settings
from .cookie_sync import CookieSyncError, sync_cookies_if_needed
from .formats import DEFAULT_DOWNLOAD_FORMAT, DEFAULT_MAX_HEIGHT, format_for_exact_height


TEMP_SUFFIXES = (".part", ".ytdl", ".temp", ".tmp")
YOUTUBE_FALLBACK_PLAYER_CLIENTS = ("web", "web_safari", "ios", "android", "tv")


class DownloadError(RuntimeError):
    pass


@dataclass(frozen=True)
class ResolutionChoice:
    height: int
    label: str
    format_selector: str


@dataclass(frozen=True)
class ResolutionProbe:
    title: str
    choices: list[ResolutionChoice]
    default_height: int | None


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
                "YouTube 下载地址返回 HTTP 403 Forbidden。通常是 yt-dlp 版本旧、VPS IP 风控、"
                "没有 YouTube 登录 cookies，或 YouTube 对当前 client 限制。先执行 "
                "`x ytdlp-update`、`x 1080p`、`x restart`。如果仍失败，把 YouTube 登录 cookies "
                "导出成 Netscape cookies.txt，放到 COOKIES_FILE，然后执行 `x cookies` 和 `x restart`。"
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


def _sync_cookies_or_fail(settings: Settings, cleanup_dir: Path | None = None) -> None:
    try:
        sync_cookies_if_needed(settings)
    except CookieSyncError as exc:
        if not (settings.cookies_file and settings.cookies_file.exists()):
            if cleanup_dir is not None:
                shutil.rmtree(cleanup_dir, ignore_errors=True)
            raise DownloadError(str(exc)) from exc


def _youtube_client_sets(settings: Settings) -> list[list[str]]:
    sets: list[list[str]] = []
    if settings.youtube_player_clients:
        sets.append(settings.youtube_player_clients)
    sets.extend([[client] for client in YOUTUBE_FALLBACK_PLAYER_CLIENTS])
    sets.append([])

    seen: set[tuple[str, ...]] = set()
    unique: list[list[str]] = []
    for clients in sets:
        key = tuple(clients)
        if key in seen:
            continue
        seen.add(key)
        unique.append(clients)
    return unique


def _base_ytdlp_options(
    url: str,
    settings: Settings,
    *,
    youtube_clients: list[str] | None = None,
) -> dict[str, object]:
    options: dict[str, object] = {
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
    if youtube_clients is None:
        youtube_clients = settings.youtube_player_clients
    if youtube_clients:
        options["extractor_args"] = {
            "youtube": {"player_client": youtube_clients},
        }
    if settings.cookies_file and settings.cookies_file.exists():
        options["cookiefile"] = str(settings.cookies_file)
    return options


def _probe_from_info(info: dict[str, object]) -> ResolutionProbe:
    formats = info.get("formats") or []
    heights: set[int] = set()
    for item in formats:
        if not isinstance(item, dict):
            continue
        vcodec = str(item.get("vcodec") or "")
        if vcodec == "none":
            continue
        try:
            height = int(item.get("height") or 0)
        except (TypeError, ValueError):
            continue
        if height > 0:
            heights.add(height)

    if not heights:
        height = int(info.get("height") or 0)
        if height > 0:
            heights.add(height)

    sorted_heights = sorted(heights, reverse=True)
    choices = [
        ResolutionChoice(
            height=height,
            label=f"{height}p",
            format_selector=format_for_exact_height(height),
        )
        for height in sorted_heights[:12]
    ]
    default_candidates = [height for height in sorted_heights if height <= DEFAULT_MAX_HEIGHT]
    default_height = default_candidates[0] if default_candidates else (sorted_heights[-1] if sorted_heights else None)
    title = str(info.get("title") or "video")
    return ResolutionProbe(title=title, choices=choices, default_height=default_height)


def _probe_score(probe: ResolutionProbe) -> tuple[int, int]:
    max_height = probe.choices[0].height if probe.choices else 0
    return max_height, len(probe.choices)


def _should_try_next_client(url: str, error: DownloadError) -> bool:
    if _url_kind(url) != "youtube":
        return False
    lowered = str(error).lower()
    return (
        "requested format is not available" in lowered
        or "http error 403" in lowered
        or "403 forbidden" in lowered
        or "forbidden" in lowered
    )


def probe_resolutions(url: str, settings: Settings) -> ResolutionProbe:
    _sync_cookies_or_fail(settings)
    client_sets = _youtube_client_sets(settings) if _url_kind(url) == "youtube" else [settings.youtube_player_clients]

    best_probe: ResolutionProbe | None = None
    last_error: Exception | None = None
    for clients in client_sets:
        options = _base_ytdlp_options(url, settings, youtube_clients=clients)
        try:
            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(url, download=False)
        except Exception as exc:
            last_error = exc
            continue

        probe = _probe_from_info(info or {})
        if best_probe is None or _probe_score(probe) > _probe_score(best_probe):
            best_probe = probe
        if probe.default_height and probe.default_height >= DEFAULT_MAX_HEIGHT:
            break

    if best_probe is not None:
        return best_probe

    message = str(last_error) if last_error else "No formats were returned."
    raise DownloadError(_friendly_download_error(url, message))


def _download_with_options(url: str, options: dict[str, object]) -> dict[str, object]:
    try:
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(url, download=True)
    except Exception as exc:
        raise DownloadError(_friendly_download_error(url, str(exc))) from exc
    return info or {}


def download_video(url: str, settings: Settings, download_format: str | None = None) -> tuple[Path, str]:
    settings.download_dir.mkdir(parents=True, exist_ok=True)
    job_dir = settings.download_dir / uuid.uuid4().hex
    job_dir.mkdir(parents=True, exist_ok=False)

    _sync_cookies_or_fail(settings, cleanup_dir=job_dir)

    selected_format = download_format or settings.download_format or DEFAULT_DOWNLOAD_FORMAT
    client_sets = _youtube_client_sets(settings) if _url_kind(url) == "youtube" else [settings.youtube_player_clients]

    info: dict[str, object] | None = None
    last_error: DownloadError | None = None
    for clients in client_sets:
        options = _base_ytdlp_options(url, settings, youtube_clients=clients)
        options.update(
            {
                "format": selected_format,
                "outtmpl": str(job_dir / "%(title).180B [%(id)s].%(ext)s"),
                "merge_output_format": settings.merge_output_format,
            }
        )
        try:
            info = _download_with_options(url, options)
            break
        except DownloadError as exc:
            last_error = exc
            if not _should_try_next_client(url, exc):
                break

    if info is None:
        shutil.rmtree(job_dir, ignore_errors=True)
        raise last_error or DownloadError("Download failed.")


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
