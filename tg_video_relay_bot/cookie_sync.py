from __future__ import annotations

import hashlib
import json
import os
import time
from pathlib import Path
from typing import Any

import requests

from .config import Settings, load_settings


class CookieSyncError(RuntimeError):
    pass


def _state_path(cookies_file: Path) -> Path:
    return cookies_file.with_name(f"{cookies_file.name}.sync.json")


def _read_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}


def _write_state(path: Path, state: dict[str, Any]) -> None:
    path.write_text(json.dumps(state, ensure_ascii=False, indent=2), encoding="utf-8")


def _looks_like_netscape_cookies(content: bytes) -> bool:
    if not content.strip():
        return False
    lowered = content[:300].lower()
    if b"<html" in lowered or b"<!doctype html" in lowered:
        return False
    text = content.decode("utf-8", errors="ignore")
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.count("\t") >= 6:
            return True
    return False


def sync_cookies_if_needed(settings: Settings, *, force: bool = False) -> str | None:
    if not settings.cookie_sync_url:
        return None
    if settings.cookies_file is None:
        raise CookieSyncError("COOKIE_SYNC_URL is set, but COOKIES_FILE is empty.")

    cookies_file = settings.cookies_file
    state_file = _state_path(cookies_file)
    state = _read_state(state_file)
    now = int(time.time())
    interval = settings.cookie_sync_interval_minutes * 60

    if not force and cookies_file.exists() and now - int(state.get("last_check", 0)) < interval:
        return None

    headers = {
        "User-Agent": "tg-video-relay-cookie-sync/1.0",
        "Cache-Control": "no-cache",
    }
    if state.get("etag"):
        headers["If-None-Match"] = str(state["etag"])
    if state.get("last_modified"):
        headers["If-Modified-Since"] = str(state["last_modified"])

    response = requests.get(settings.cookie_sync_url, headers=headers, timeout=60)
    if response.status_code == 304:
        state["last_check"] = now
        _write_state(state_file, state)
        return "cookies.txt not changed."
    if response.status_code >= 400:
        raise CookieSyncError(f"Cookie sync failed: HTTP {response.status_code}")

    content = response.content
    if not _looks_like_netscape_cookies(content):
        raise CookieSyncError(
            "Downloaded cookie file does not look like Netscape cookies.txt. "
            "Use a direct file link, not a preview page."
        )

    digest = hashlib.sha256(content).hexdigest()
    if cookies_file.exists() and digest == state.get("sha256"):
        state["last_check"] = now
        _write_state(state_file, state)
        return "cookies.txt already current."

    cookies_file.parent.mkdir(parents=True, exist_ok=True)
    temp_path = cookies_file.with_name(f".{cookies_file.name}.tmp")
    temp_path.write_bytes(content)
    os.chmod(temp_path, 0o600)
    temp_path.replace(cookies_file)
    os.chmod(cookies_file, 0o600)

    state = {
        "last_check": now,
        "etag": response.headers.get("ETag", ""),
        "last_modified": response.headers.get("Last-Modified", ""),
        "sha256": digest,
        "bytes": len(content),
    }
    _write_state(state_file, state)
    return f"cookies.txt synced: {len(content)} bytes."


def main() -> None:
    settings = load_settings()
    message = sync_cookies_if_needed(settings, force=True)
    print(message or "COOKIE_SYNC_URL is empty; nothing to sync.")


if __name__ == "__main__":
    main()
