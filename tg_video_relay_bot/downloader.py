from __future__ import annotations

import logging
import shutil
import uuid
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

import yt_dlp

try:
    from yt_dlp.networking.impersonate import ImpersonateTarget
except ImportError:  # Older yt-dlp versions can still use the normal request path.
    ImpersonateTarget = None

from .config import Settings
from .cookie_sync import CookieSyncError, sync_cookies_if_needed
from .formats import DEFAULT_DOWNLOAD_FORMAT, DEFAULT_MAX_HEIGHT, SAFE_FALLBACK_DOWNLOAD_FORMAT


TEMP_SUFFIXES = (".part", ".ytdl", ".temp", ".tmp")
YOUTUBE_FALLBACK_PLAYER_CLIENTS = ("web", "web_safari", "ios", "android", "tv")
LOGGER = logging.getLogger(__name__)


class DownloadError(RuntimeError):
    pass


@dataclass(frozen=True)
class ResolutionChoice:
    height: int
    label: str
    format_selector: str
    size_label: str | None = None


@dataclass(frozen=True)
class ResolutionProbe:
    title: str
    choices: list[ResolutionChoice]
    default_height: int | None


@dataclass(frozen=True)
class DownloadResult:
    file_path: Path
    title: str
    format_summary: str


def _canonicalize_platform_url(url: str) -> str:
    try:
        parsed = urlsplit(url)
    except ValueError:
        return url
    hostname = (parsed.hostname or "").lower()
    if hostname == "pornhub.com" or hostname.endswith(".pornhub.com"):
        return urlunsplit(("https", "www.pornhub.com", parsed.path, parsed.query, parsed.fragment))
    return url


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
    if "pornhub.com" in lowered:
        return "pornhub"
    return "generic"


def _headers_for(url: str) -> dict[str, str]:
    kind = _url_kind(url)
    referers = {
        "youtube": "https://www.youtube.com/",
        "tiktok": "https://www.tiktok.com/",
        "douyin": "https://www.douyin.com/",
        "twitter": "https://x.com/",
        "pornhub": "https://www.pornhub.com/",
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
    if "drm" in lowered and "protected" in lowered:
        return (
            "yt-dlp 当前拿到的是 DRM/受限视频流，已避开已识别的 DRM 格式再试。"
            "如果电脑 IDM 能下载，通常是浏览器登录状态、YouTube cookies、VPS IP 或客户端识别不同。"
            "请更新 cookies_youtube.txt 后执行 `x cookies`、`x ytdlp-update`、`x restart`，"
            "并优先选择非 HDR 的普通分辨率。"
        )
    if "requested format is not available" in lowered and kind == "youtube":
        return (
            "YouTube 当前没有返回这个清晰度对应的可下载格式。请先确认 "
            "COOKIES_FILE_YOUTUBE=/opt/tg-video-relay-bot/cookies_youtube.txt 已上传且有效，"
            "再执行 `x ytdlp-update`、`x restart`。"
        )
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
        if kind == "pornhub":
            return (
                "Pornhub returned HTTP 403 Forbidden. Run `x ytdlp-update` first. If it still fails, "
                "export Netscape cookies to cookies_pornhub.txt, set COOKIES_FILE_PORNHUB, then restart."
            )
    if kind == "pornhub" and any(marker in lowered for marker in ("login required", "sign in", "age verification")):
        return (
            "Pornhub requires a browser session for this video. Export Netscape cookies to "
            "cookies_pornhub.txt, set COOKIES_FILE_PORNHUB, then restart the bot."
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
        has_any_cookie_file = any(
            path and path.exists()
            for path in (
                settings.cookies_file_x,
                settings.cookies_file_youtube,
                settings.cookies_file_pornhub,
                settings.cookies_file,
            )
        )
        if not has_any_cookie_file:
            if cleanup_dir is not None:
                shutil.rmtree(cleanup_dir, ignore_errors=True)
            raise DownloadError(str(exc)) from exc


def _cookie_file_for_url(url: str, settings: Settings) -> Path | None:
    kind = _url_kind(url)
    candidates: list[Path | None]
    if kind == "youtube":
        candidates = [settings.cookies_file_youtube, settings.cookies_file]
    elif kind == "twitter":
        candidates = [settings.cookies_file_x, settings.cookies_file]
    elif kind == "pornhub":
        candidates = [settings.cookies_file_pornhub, settings.cookies_file]
    else:
        candidates = [settings.cookies_file]

    for path in candidates:
        if path and path.exists():
            return path
    return None


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


def _request_profiles(url: str) -> list[tuple[str, object | None]]:
    if _url_kind(url) != "pornhub" or ImpersonateTarget is None:
        return [("default", None)]
    return [
        ("chrome", ImpersonateTarget.from_str("chrome")),
        ("default", None),
    ]


def _base_ytdlp_options(
    url: str,
    settings: Settings,
    *,
    youtube_clients: list[str] | None = None,
    impersonate_target: object | None = None,
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
    if impersonate_target is not None:
        options["impersonate"] = impersonate_target
    if youtube_clients is None:
        youtube_clients = settings.youtube_player_clients
    if youtube_clients:
        options["extractor_args"] = {
            "youtube": {"player_client": youtube_clients},
        }
    cookie_file = _cookie_file_for_url(url, settings)
    if cookie_file:
        options["cookiefile"] = str(cookie_file)
    return options


def _probe_from_info(info: dict[str, object]) -> ResolutionProbe:
    formats = info.get("formats") or []
    video_by_height: dict[int, dict[str, object]] = {}
    audio_choice: dict[str, object] | None = None
    try:
        duration = float(info.get("duration") or 0)
    except (TypeError, ValueError):
        duration = 0
    for item in formats:
        if not isinstance(item, dict):
            continue
        if _format_has_drm(item):
            continue
        if not _is_video_or_audio_format(item):
            continue
        vcodec = str(item.get("vcodec") or "")
        acodec = str(item.get("acodec") or "")
        size = _format_size_bytes(item, duration)
        if vcodec == "none":
            if acodec != "none" and _format_id(item):
                if audio_choice is None or _format_score(item, duration) > _format_score(audio_choice, duration):
                    audio_choice = item
            continue
        try:
            height = int(item.get("height") or 0)
        except (TypeError, ValueError):
            continue
        if height > 0 and _format_id(item):
            current = video_by_height.get(height)
            if current is None or _format_score(item, duration) > _format_score(current, duration):
                video_by_height[height] = item

    if not video_by_height:
        height = int(info.get("height") or 0)
        if height > 0 and not _format_has_drm(info):
            video_by_height[height] = info

    audio_size = _format_size_bytes(audio_choice, duration) if audio_choice else 0
    audio_id = _format_id(audio_choice) if audio_choice else None
    sorted_heights = sorted(video_by_height, reverse=True)
    choices = [
        ResolutionChoice(
            height=height,
            label=_resolution_label(height, _format_size_bytes(video_by_height[height], duration), audio_size),
            format_selector=_format_selector_for_choice(video_by_height[height], audio_id),
            size_label=_size_label(_combined_size(_format_size_bytes(video_by_height[height], duration), audio_size)),
        )
        for height in sorted_heights[:12]
    ]
    default_candidates = [height for height in sorted_heights if height <= DEFAULT_MAX_HEIGHT]
    default_height = default_candidates[0] if default_candidates else (sorted_heights[-1] if sorted_heights else None)
    title = str(info.get("title") or "video")
    return ResolutionProbe(title=title, choices=choices, default_height=default_height)


def _format_id(item: dict[str, object] | None) -> str | None:
    if not item:
        return None
    value = str(item.get("format_id") or "").strip()
    return value or None


def _format_has_drm(item: dict[str, object]) -> bool:
    for key in ("has_drm", "drm"):
        value = item.get(key)
        if isinstance(value, bool):
            return value
        if isinstance(value, (int, float)):
            return value != 0
        if isinstance(value, str):
            lowered = value.lower()
            if lowered in {"1", "true", "yes", "drm", "protected"}:
                return True
    text_fields = (
        str(item.get("protocol") or ""),
        str(item.get("format") or ""),
        str(item.get("format_note") or ""),
    )
    return any("drm" in value.lower() for value in text_fields)


def _is_video_or_audio_format(item: dict[str, object]) -> bool:
    ext = str(item.get("ext") or "").lower()
    protocol = str(item.get("protocol") or "").lower()
    format_note = str(item.get("format_note") or "").lower()
    format_text = str(item.get("format") or "").lower()
    vcodec = str(item.get("vcodec") or "").lower()
    acodec = str(item.get("acodec") or "").lower()
    if ext in {"mhtml", "html", "json"}:
        return False
    if "storyboard" in format_note or "storyboard" in format_text:
        return False
    if vcodec in {"images", "none"} and acodec in {"none", ""}:
        return False
    if protocol == "mhtml":
        return False
    return True


def _format_score(item: dict[str, object], duration: float) -> tuple[int, int, float, int]:
    ext = str(item.get("ext") or "").lower()
    vcodec = str(item.get("vcodec") or "")
    acodec = str(item.get("acodec") or "")
    try:
        tbr = float(item.get("tbr") or 0)
    except (TypeError, ValueError):
        tbr = 0
    return (
        1 if ext == "mp4" else 0,
        1 if vcodec != "none" and acodec != "none" else 0,
        tbr,
        _format_size_bytes(item, duration),
    )


def _format_selector_for_choice(video_item: dict[str, object], audio_id: str | None) -> str:
    video_id = _format_id(video_item)
    if not video_id:
        return SAFE_FALLBACK_DOWNLOAD_FORMAT
    acodec = str(video_item.get("acodec") or "")
    if acodec != "none":
        return video_id
    if audio_id:
        return f"{video_id}+{audio_id}/{video_id}"
    return video_id


def _format_size_bytes(item: dict[str, object] | None, duration: float = 0) -> int:
    if item is None:
        return 0
    for key in ("filesize", "filesize_approx"):
        value = item.get(key)
        try:
            size = int(float(value or 0))
        except (TypeError, ValueError):
            size = 0
        if size > 0:
            return size
    try:
        tbr = float(item.get("tbr") or 0)
    except (TypeError, ValueError):
        tbr = 0
    if duration > 0 and tbr > 0:
        return int((tbr * 1000 / 8) * duration)
    return 0


def _combined_size(video_size: int, audio_size: int) -> int:
    if video_size <= 0:
        return 0
    return video_size + max(audio_size, 0)


def _size_label(size_bytes: int) -> str | None:
    if size_bytes <= 0:
        return None
    size_mb = size_bytes / 1024 / 1024
    if size_mb >= 1024:
        return f"{size_mb / 1024:.1f} GB"
    return f"{size_mb:.0f} MB"


def _resolution_label(height: int, video_size: int, audio_size: int) -> str:
    size_label = _size_label(_combined_size(video_size, audio_size))
    if size_label:
        return f"{height}p · {size_label}"
    return f"{height}p · 大小未知"


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
        or "当前没有返回这个清晰度" in str(error)
        or "drm/受限" in str(error).lower()
    )


def probe_resolutions(url: str, settings: Settings) -> ResolutionProbe:
    url = _canonicalize_platform_url(url)
    _sync_cookies_or_fail(settings)
    client_sets = _youtube_client_sets(settings) if _url_kind(url) == "youtube" else [[]]
    request_profiles = _request_profiles(url)

    best_probe: ResolutionProbe | None = None
    last_error: Exception | None = None
    for request_profile, impersonate_target in request_profiles:
        for clients in client_sets:
            options = _base_ytdlp_options(
                url,
                settings,
                youtube_clients=clients,
                impersonate_target=impersonate_target,
            )
            options["format"] = SAFE_FALLBACK_DOWNLOAD_FORMAT
            options["ignore_no_formats_error"] = True
            LOGGER.info(
                "Probing formats: url=%s clients=%s request_profile=%s",
                url,
                ",".join(clients) or "default",
                request_profile,
            )
            try:
                with yt_dlp.YoutubeDL(options) as ydl:
                    info = ydl.extract_info(url, download=False)
            except Exception as exc:
                last_error = exc
                LOGGER.warning(
                    "Format probe failed: url=%s clients=%s request_profile=%s error=%s",
                    url,
                    ",".join(clients) or "default",
                    request_profile,
                    exc,
                )
                continue

            probe = _probe_from_info(info or {})
            LOGGER.info(
                "Format probe result: url=%s clients=%s request_profile=%s title=%r choices=%s default=%s",
                url,
                ",".join(clients) or "default",
                request_profile,
                probe.title,
                ", ".join(f"{choice.height}p[{choice.format_selector}]" for choice in probe.choices),
                probe.default_height,
            )
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
        LOGGER.warning(
            "yt-dlp download failed: url=%s format=%s clients=%s error=%s",
            url,
            options.get("format"),
            (options.get("extractor_args") or {}).get("youtube", {}).get("player_client", "default")
            if isinstance(options.get("extractor_args"), dict)
            else "default",
            exc,
        )
        raise DownloadError(_friendly_download_error(url, str(exc))) from exc
    return info or {}


def _download_format_summary(info: dict[str, object]) -> str:
    format_id = str(info.get("format_id") or "unknown")
    ext = str(info.get("ext") or "unknown")
    resolution = str(info.get("resolution") or "")
    width = info.get("width")
    height = info.get("height")
    if not resolution and width and height:
        resolution = f"{width}x{height}"
    vcodec = str(info.get("vcodec") or "")
    acodec = str(info.get("acodec") or "")
    parts = [f"format_id={format_id}", f"ext={ext}"]
    if resolution:
        parts.append(f"resolution={resolution}")
    if vcodec:
        parts.append(f"vcodec={vcodec}")
    if acodec:
        parts.append(f"acodec={acodec}")
    return ", ".join(parts)


def download_video(url: str, settings: Settings, download_format: str | None = None) -> DownloadResult:
    url = _canonicalize_platform_url(url)
    settings.download_dir.mkdir(parents=True, exist_ok=True)
    job_dir = settings.download_dir / uuid.uuid4().hex
    job_dir.mkdir(parents=True, exist_ok=False)

    _sync_cookies_or_fail(settings, cleanup_dir=job_dir)

    selected_format = download_format or settings.download_format or DEFAULT_DOWNLOAD_FORMAT
    format_attempts = [selected_format]
    allow_fallback = download_format is None
    if allow_fallback and SAFE_FALLBACK_DOWNLOAD_FORMAT not in format_attempts:
        format_attempts.append(SAFE_FALLBACK_DOWNLOAD_FORMAT)
    client_sets = _youtube_client_sets(settings) if _url_kind(url) == "youtube" else [[]]
    request_profiles = _request_profiles(url)

    info: dict[str, object] | None = None
    last_error: DownloadError | None = None
    for format_selector in format_attempts:
        for request_profile, impersonate_target in request_profiles:
            for clients in client_sets:
                LOGGER.info(
                    "Downloading video: url=%s format=%s clients=%s request_profile=%s allow_fallback=%s",
                    url,
                    format_selector,
                    ",".join(clients) or "default",
                    request_profile,
                    allow_fallback,
                )
                options = _base_ytdlp_options(
                    url,
                    settings,
                    youtube_clients=clients,
                    impersonate_target=impersonate_target,
                )
                options.update(
                    {
                        "format": format_selector,
                        "outtmpl": str(job_dir / "%(title).180B [%(id)s].%(ext)s"),
                        "merge_output_format": settings.merge_output_format,
                    }
                )
                try:
                    info = _download_with_options(url, options)
                    LOGGER.info(
                        "Download succeeded: url=%s format=%s clients=%s request_profile=%s result=%s",
                        url,
                        format_selector,
                        ",".join(clients) or "default",
                        request_profile,
                        _download_format_summary(info),
                    )
                    break
                except DownloadError as exc:
                    last_error = exc
                    if not _should_try_next_client(url, exc):
                        break
                    LOGGER.info(
                        "Trying next YouTube client after failure: url=%s format=%s failed_clients=%s",
                        url,
                        format_selector,
                        ",".join(clients) or "default",
                    )
            if info is not None:
                break
        if info is not None:
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
    return DownloadResult(file_path=file_path, title=title, format_summary=_download_format_summary(info))


def cleanup_download(file_path: Path) -> None:
    parent = file_path.parent
    if parent.exists():
        shutil.rmtree(parent, ignore_errors=True)
