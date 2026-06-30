from __future__ import annotations

import re


URL_RE = re.compile(r"https?://[^\s<>()\"']+", re.IGNORECASE)

SUPPORTED_HOST_HINTS = (
    "youtube.com",
    "youtu.be",
    "tiktok.com",
    "douyin.com",
    "iesdouyin.com",
    "x.com",
    "twitter.com",
    "video.twimg.com",
)

DIRECT_MEDIA_EXTENSIONS = (
    ".m3u8",
    ".mp4",
    ".mov",
    ".webm",
)


def _is_supported_url(url: str) -> bool:
    lowered = url.lower()
    path_without_query = lowered.split("?", 1)[0]
    return any(host in lowered for host in SUPPORTED_HOST_HINTS) or path_without_query.endswith(
        DIRECT_MEDIA_EXTENSIONS
    )


def extract_urls(text: str) -> list[str]:
    seen: set[str] = set()
    urls: list[str] = []
    for match in URL_RE.findall(text or ""):
        url = match.rstrip(".,;!?)]}")
        if _is_supported_url(url) and url not in seen:
            seen.add(url)
            urls.append(url)
    return urls


def trim_caption(text: str, limit: int = 1024) -> str:
    clean = " ".join((text or "").split())
    if len(clean) <= limit:
        return clean
    return clean[: limit - 1] + "…"
