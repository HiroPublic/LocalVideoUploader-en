from __future__ import annotations

from datetime import datetime
from pathlib import Path
from types import SimpleNamespace

from .config import DEFAULT_OFFSET, DEFAULT_PLAYLIST_PRIVACY_STATUS, DEFAULT_PRIVACY_STATUS, DEFAULT_TIMEZONE
from .exceptions import ValidationError
from .media_info import probe_media_info
from .models import VideoMetadataInput

ALLOWED_PRIVACY_STATUSES = {"private", "unlisted", "public"}


def parse_capture_datetime(value: str) -> datetime:
    normalized = value.strip()
    candidates = [
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%d %H:%M",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M",
    ]
    for fmt in candidates:
        try:
            return datetime.strptime(normalized, fmt)
        except ValueError:
            continue
    raise ValidationError(
        "撮影日時の形式が不正です。例: 2026-04-07 14:32:10 または 2026-04-07T14:32"
    )


def parse_multi_value(raw_values: list[str] | None) -> list[str]:
    if not raw_values:
        return []
    items: list[str] = []
    for raw in raw_values:
        for part in raw.split(","):
            value = part.strip()
            if value:
                items.append(value)
    seen: set[str] = set()
    unique_items: list[str] = []
    for item in items:
        if item.casefold() in seen:
            continue
        seen.add(item.casefold())
        unique_items.append(item)
    return unique_items


def build_video_metadata_input(args: object) -> VideoMetadataInput:
    return build_video_metadata_input_from_mapping(
        {
            "video": getattr(args, "video"),
            "capture_datetime": getattr(args, "capture_datetime"),
            "timezone": getattr(args, "timezone", DEFAULT_TIMEZONE),
            "offset_time_original": getattr(args, "offset_time_original", DEFAULT_OFFSET),
            "place": getattr(args, "place", ""),
            "content": getattr(args, "content", ""),
            "event_name": getattr(args, "event_name", ""),
            "participants": getattr(args, "participants", None),
            "camera_model": getattr(args, "camera_model", ""),
            "playlists": getattr(args, "playlists", None),
            "note": getattr(args, "note", ""),
            "library_name": getattr(args, "library_name", "Local Files"),
            "capture_date_source": getattr(args, "capture_date_source", "manual_input"),
            "original_capture_datetime": getattr(args, "original_capture_datetime", None),
            "privacy_status": getattr(args, "privacy_status", DEFAULT_PRIVACY_STATUS),
            "playlist_privacy_status": getattr(
                args,
                "playlist_privacy_status",
                DEFAULT_PLAYLIST_PRIVACY_STATUS,
            ),
        }
    )


def build_video_metadata_input_from_mapping(values: dict[str, object]) -> VideoMetadataInput:
    args = SimpleNamespace(**values)
    video_path = Path(getattr(args, "video")).expanduser()
    if not video_path.exists():
        raise ValidationError(f"動画ファイルが見つかりません: {video_path}")
    if not video_path.is_file():
        raise ValidationError(f"動画パスがファイルではありません: {video_path}")

    privacy_status = getattr(args, "privacy_status", DEFAULT_PRIVACY_STATUS)
    if privacy_status not in ALLOWED_PRIVACY_STATUSES:
        raise ValidationError(
            f"公開設定が不正です: {privacy_status}. {sorted(ALLOWED_PRIVACY_STATUSES)} から選択してください。"
        )
    playlist_privacy_status = getattr(args, "playlist_privacy_status", DEFAULT_PLAYLIST_PRIVACY_STATUS)
    if playlist_privacy_status not in ALLOWED_PRIVACY_STATUSES:
        raise ValidationError(
            f"プレイリスト公開設定が不正です: {playlist_privacy_status}. {sorted(ALLOWED_PRIVACY_STATUSES)} から選択してください。"
        )

    capture_datetime = parse_capture_datetime(getattr(args, "capture_datetime"))
    timezone = (getattr(args, "timezone", DEFAULT_TIMEZONE) or DEFAULT_TIMEZONE).strip() or DEFAULT_TIMEZONE
    offset = (getattr(args, "offset_time_original", DEFAULT_OFFSET) or DEFAULT_OFFSET).strip() or DEFAULT_OFFSET
    original_capture = (
        parse_capture_datetime(getattr(args, "original_capture_datetime"))
        if getattr(args, "original_capture_datetime", None)
        else None
    )

    media_info = probe_media_info(video_path)

    return VideoMetadataInput(
        video_path=video_path,
        capture_datetime=capture_datetime,
        file_size_bytes=media_info.file_size_bytes,
        duration_seconds=media_info.duration_seconds,
        width=media_info.width,
        height=media_info.height,
        timezone=timezone,
        offset_time_original=offset,
        place=(getattr(args, "place", "") or "").strip(),
        content=(getattr(args, "content", "") or "").strip(),
        event_name=(getattr(args, "event_name", "") or "").strip(),
        participants=parse_multi_value(getattr(args, "participants", None)),
        camera_model=(getattr(args, "camera_model", "") or "").strip(),
        playlists=parse_multi_value(getattr(args, "playlists", None)),
        note=(getattr(args, "note", "") or "").strip(),
        original_filename=video_path.name,
        library_name=(getattr(args, "library_name", None) or "Local Files").strip(),
        capture_date_source=(getattr(args, "capture_date_source", None) or "manual_input").strip(),
        original_capture_datetime=original_capture,
        privacy_status=privacy_status,
        playlist_privacy_status=playlist_privacy_status,
    )
