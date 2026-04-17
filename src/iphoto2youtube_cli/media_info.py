from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(slots=True)
class MediaInfo:
    file_size_bytes: int
    duration_seconds: float | None = None
    width: int | None = None
    height: int | None = None


def probe_media_info(video_path: Path) -> MediaInfo:
    resolved_path = video_path.resolve()
    default_size = resolved_path.stat().st_size
    command = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration,size:stream=width,height",
        "-of",
        "json",
        str(resolved_path),
    ]
    try:
        completed = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return MediaInfo(file_size_bytes=default_size)

    payload = json.loads(completed.stdout or "{}")
    format_info = payload.get("format", {})
    streams = payload.get("streams", [])

    width = None
    height = None
    for stream in streams:
        if "width" in stream and "height" in stream:
            width = int(stream["width"])
            height = int(stream["height"])
            break

    duration_raw = format_info.get("duration")
    size_raw = format_info.get("size")
    return MediaInfo(
        file_size_bytes=int(size_raw) if size_raw else default_size,
        duration_seconds=float(duration_raw) if duration_raw else None,
        width=width,
        height=height,
    )


def format_duration(duration_seconds: float | None) -> str:
    if duration_seconds is None:
        return "不明"
    total_seconds = int(round(duration_seconds))
    hours, remainder = divmod(total_seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def format_resolution(width: int | None, height: int | None) -> str:
    if not width or not height:
        return "不明"
    return f"{width}x{height}"


def format_file_size(file_size_bytes: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(file_size_bytes)
    unit = units[0]
    for candidate in units[1:]:
        if size < 1024:
            break
        size /= 1024
        unit = candidate
    if unit == "B":
        return f"{int(size)} {unit}"
    return f"{size:.1f} {unit}"
