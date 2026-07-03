from __future__ import annotations


DEFAULT_MAX_HEIGHT = 1080


def format_for_max_height(max_height: int = DEFAULT_MAX_HEIGHT) -> str:
    return (
        f"bv*[height<={max_height}][ext=mp4]+ba[ext=m4a]/"
        f"bv*[height<={max_height}]+ba/"
        f"b[height<={max_height}]/"
        f"best[height<={max_height}]/best"
    )


def format_for_exact_height(height: int) -> str:
    return (
        f"bv*[height={height}][ext=mp4]+ba[ext=m4a]/"
        f"bv*[height={height}]+ba/"
        f"b[height={height}]/"
        f"best[height={height}]"
    )


DEFAULT_DOWNLOAD_FORMAT = format_for_max_height()
