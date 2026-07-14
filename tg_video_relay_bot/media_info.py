from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class VideoInfo:
    width: int
    height: int

    @property
    def label(self) -> str:
        return f"{self.width}x{self.height}"


def probe_video_info(file_path: Path) -> VideoInfo | None:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height:stream_tags=rotate:stream_side_data=rotation",
        "-of",
        "json",
        str(file_path),
    ]
    result = subprocess.run(command, capture_output=True, check=False, text=True)
    if result.returncode != 0:
        return None
    try:
        payload = json.loads(result.stdout)
        stream = payload["streams"][0]
        width = int(stream["width"])
        height = int(stream["height"])
        rotation = int(stream.get("tags", {}).get("rotate", 0) or 0)
        for side_data in stream.get("side_data_list", []):
            if "rotation" in side_data:
                rotation = int(float(side_data["rotation"]))
                break
    except (KeyError, IndexError, TypeError, ValueError, json.JSONDecodeError):
        return None
    if width <= 0 or height <= 0:
        return None
    if abs(rotation) % 180 == 90:
        width, height = height, width
    return VideoInfo(width=width, height=height)
