from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .config import Settings


class CompressionError(RuntimeError):
    pass


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, capture_output=True, check=False, text=True)


def _probe_duration(file_path: Path) -> float:
    result = _run(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            str(file_path),
        ]
    )
    if result.returncode != 0:
        raise CompressionError(f"ffprobe failed: {result.stderr.strip()}")

    try:
        payload = json.loads(result.stdout)
        duration = float(payload["format"]["duration"])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise CompressionError("Could not read video duration with ffprobe.") from exc

    if duration <= 0:
        raise CompressionError("Video duration is invalid.")
    return duration


def _target_video_bitrate(duration: float, target_bytes: int, audio_kbps: int) -> int:
    audio_bps = audio_kbps * 1000
    total_bps = int((target_bytes * 8) / duration)
    return max(180_000, total_bps - audio_bps)


def _compress_once(
    input_path: Path,
    output_path: Path,
    *,
    duration: float,
    target_bytes: int,
    height: int,
    audio_kbps: int,
) -> None:
    video_bps = _target_video_bitrate(duration, target_bytes, audio_kbps)
    command = [
        "ffmpeg",
        "-y",
        "-i",
        str(input_path),
        "-map",
        "0:v:0",
        "-map",
        "0:a?",
        "-vf",
        f"scale=-2:{height}:flags=lanczos,setsar=1",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-b:v",
        str(video_bps),
        "-maxrate",
        str(video_bps),
        "-bufsize",
        str(video_bps * 2),
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        f"{audio_kbps}k",
        "-movflags",
        "+faststart",
        "-metadata:s:v:0",
        "rotate=0",
        str(output_path),
    ]
    result = _run(command)
    if result.returncode != 0:
        raise CompressionError(f"ffmpeg failed: {result.stderr.strip()[-1200:]}")


def prepare_upload_file(file_path: Path, settings: Settings) -> tuple[Path, str | None]:
    original_size = file_path.stat().st_size
    if original_size <= settings.max_upload_bytes:
        return file_path, None

    if not settings.auto_compress:
        raise CompressionError(
            f"File is {original_size / 1024 / 1024:.1f} MB, above MAX_UPLOAD_MB={settings.max_upload_mb}. "
            "Enable AUTO_COMPRESS=true or lower DOWNLOAD_FORMAT."
        )

    duration = _probe_duration(file_path)
    attempts = [
        (720, 0.90),
        (540, 0.78),
        (480, 0.66),
        (360, 0.54),
    ]

    best_output: Path | None = None
    for height, ratio in attempts:
        output_path = file_path.with_name(f"{file_path.stem}.tg-{height}p.mp4")
        target_bytes = int(settings.max_upload_bytes * ratio)
        _compress_once(
            file_path,
            output_path,
            duration=duration,
            target_bytes=target_bytes,
            height=height,
            audio_kbps=settings.compress_audio_kbps,
        )
        best_output = output_path
        if output_path.stat().st_size <= settings.max_upload_bytes:
            before_mb = original_size / 1024 / 1024
            after_mb = output_path.stat().st_size / 1024 / 1024
            return output_path, f"文件超过上传限制，已自动压缩：{before_mb:.1f} MB -> {after_mb:.1f} MB"

    if best_output is not None:
        raise CompressionError(
            f"Compressed file is still too large: {best_output.stat().st_size / 1024 / 1024:.1f} MB. "
            "Try DOWNLOAD_FORMAT=best[height<=480]/best or lower MAX_UPLOAD_MB."
        )

    raise CompressionError("Compression did not produce an output file.")
