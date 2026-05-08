from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime

from .media_info import format_duration, format_resolution
from .models import ComposedMetadata, VideoMetadataInput

PLACE_FALLBACK = "場所未設定"
CONTENT_FALLBACK = "内容未設定"
EVENT_FALLBACK = "イベント未設定"
PARTICIPANTS_FALLBACK = "参加者未設定"
CAMERA_FALLBACK = "カメラ種別未設定"
YOUTUBE_TITLE_MAX_CHARS = 100
YOUTUBE_DESCRIPTION_MAX_BYTES = 5000
YOUTUBE_TAGS_MAX_CHARS = 500


def normalize_for_lookup(value: str) -> str:
    compact = re.sub(r"\s+", " ", value.strip())
    return compact


def sanitize_title_component(value: str) -> str:
    normalized = normalize_for_lookup(value)
    return re.sub(r'[\\/:*?"<>|]+', "-", normalized).replace(" ", "")


def normalize_user_title(value: str) -> str:
    compact = normalize_for_lookup(value)
    return _truncate_chars(sanitize_youtube_text(compact), YOUTUBE_TITLE_MAX_CHARS)


def normalize_user_description(value: str) -> str:
    return _truncate_utf8_bytes(sanitize_youtube_text(value.strip()), YOUTUBE_DESCRIPTION_MAX_BYTES)


def sanitize_youtube_text(value: str) -> str:
    return value.replace("<", "＜").replace(">", "＞")


def _truncate_chars(value: str, max_chars: int) -> str:
    if len(value) <= max_chars:
        return value
    return value[:max_chars].rstrip()


def _truncate_utf8_bytes(value: str, max_bytes: int) -> str:
    encoded = value.encode("utf-8")
    if len(encoded) <= max_bytes:
        return value
    truncated = encoded[:max_bytes]
    while truncated:
        try:
            return truncated.decode("utf-8").rstrip()
        except UnicodeDecodeError as exc:
            truncated = truncated[: exc.start]
    return ""


def _youtube_tag_cost(value: str) -> int:
    return len(value) + (2 if " " in value else 0)


def build_title_base(metadata: VideoMetadataInput) -> str:
    parts = [
        metadata.capture_datetime.strftime("%Y-%m-%d") + "-" + sanitize_title_component(metadata.timezone or "JST"),
        sanitize_title_component(metadata.place or PLACE_FALLBACK),
    ]
    event_component = sanitize_title_component(metadata.event_name) if metadata.event_name else ""
    content_component = sanitize_title_component(metadata.content) if metadata.content else ""
    if event_component:
        parts.append(event_component)
    if content_component and content_component != event_component:
        parts.append(content_component)
    return "_".join(parts)


def build_title(metadata: VideoMetadataInput, collision_index: int = 0) -> tuple[str, str, int]:
    if metadata.custom_title:
        title = normalize_user_title(metadata.custom_title)
        return title, title, 0
    base = build_title_base(metadata)
    suffix = "" if collision_index <= 0 else f"_{collision_index:02d}"
    safe_base = _truncate_chars(base, YOUTUBE_TITLE_MAX_CHARS - len(suffix))
    if collision_index <= 0:
        return safe_base, safe_base, 0
    return f"{safe_base}{suffix}", safe_base, collision_index


def _format_dt(value: datetime, timezone: str) -> str:
    return f"{value.strftime('%Y-%m-%d %H:%M:%S')} {timezone}"


def _coalesce(value: str, fallback: str) -> str:
    return value if value else fallback


def build_tags(metadata: VideoMetadataInput) -> list[str]:
    candidates = [
        metadata.capture_datetime.strftime("%Y-%m-%d"),
        metadata.capture_datetime.strftime("%Y"),
        metadata.capture_datetime.strftime("%Y-%m"),
        metadata.timezone,
        metadata.place,
        metadata.content,
        metadata.event_name,
        *metadata.participants,
        metadata.camera_model,
    ]
    normalized: list[str] = []
    seen: set[str] = set()
    current_cost = 0
    placeholders = {PLACE_FALLBACK, CONTENT_FALLBACK, EVENT_FALLBACK, CAMERA_FALLBACK, PARTICIPANTS_FALLBACK}
    for candidate in candidates:
        value = sanitize_youtube_text(normalize_for_lookup(candidate))
        if not value or value in placeholders:
            continue
        key = value.casefold()
        if key in seen:
            continue
        addition_cost = _youtube_tag_cost(value) + (1 if normalized else 0)
        if current_cost + addition_cost > YOUTUBE_TAGS_MAX_CHARS:
            continue
        seen.add(key)
        normalized.append(f"#{value}")
        current_cost += addition_cost
    return normalized


def build_description(
    metadata: VideoMetadataInput,
    tags: list[str],
    uploaded_at: datetime,
) -> str:
    if metadata.custom_description:
        return normalize_user_description(metadata.custom_description)
    participants_display = ", ".join(metadata.participants) if metadata.participants else PARTICIPANTS_FALLBACK
    participants_key = " | ".join(metadata.participants) if metadata.participants else PARTICIPANTS_FALLBACK
    place_value = _coalesce(metadata.place, PLACE_FALLBACK)
    event_value = _coalesce(metadata.event_name, EVENT_FALLBACK)
    camera_value = _coalesce(metadata.camera_model, CAMERA_FALLBACK)
    original_capture = (
        _format_dt(metadata.original_capture_datetime, metadata.timezone)
        if metadata.original_capture_datetime
        else _format_dt(metadata.capture_datetime, metadata.timezone)
    )
    duration_text = format_duration(metadata.duration_seconds)
    resolution_text = format_resolution(metadata.width, metadata.height)
    lines = [
        "[検索用メタデータ]",
        f"撮影日: {metadata.capture_datetime.strftime('%Y-%m-%d')}",
        f"撮影日時: {sanitize_youtube_text(_format_dt(metadata.capture_datetime, metadata.timezone))}",
        f"時間帯: {sanitize_youtube_text(metadata.timezone)}",
        f"OffsetTimeOriginal: {sanitize_youtube_text(metadata.offset_time_original)}",
        f"基準日時ソース: {sanitize_youtube_text(metadata.capture_date_source)}",
        f"元の撮影日時: {sanitize_youtube_text(original_capture)}",
        f"場所: {sanitize_youtube_text(place_value)}",
        f"イベント名: {sanitize_youtube_text(event_value)}",
        f"参加者: {sanitize_youtube_text(participants_display)}",
        f"カメラ種別: {sanitize_youtube_text(camera_value)}",
        f"人物検索キー: {sanitize_youtube_text(participants_key)}",
        f"場所検索キー: {sanitize_youtube_text(place_value)}",
        f"タグ: {' '.join(tags)}",
        f"ライブラリ名: {sanitize_youtube_text(metadata.library_name)}",
        f"元ファイル名: {sanitize_youtube_text(metadata.original_filename)}",
        f"動画時間: {duration_text}",
        f"解像度: {resolution_text}",
        f"アップロード日時: {sanitize_youtube_text(_format_dt(uploaded_at, metadata.timezone))}",
        "",
        "[補足メモ]",
        sanitize_youtube_text(metadata.note or ""),
    ]
    return _truncate_utf8_bytes("\n".join(lines), YOUTUBE_DESCRIPTION_MAX_BYTES)


def compose_metadata(
    metadata: VideoMetadataInput,
    collision_index: int = 0,
    uploaded_at: datetime | None = None,
) -> ComposedMetadata:
    title, title_base, sequence = build_title(metadata, collision_index=collision_index)
    tags = build_tags(metadata)
    description = build_description(
        metadata=metadata,
        tags=tags,
        uploaded_at=uploaded_at or datetime.now(),
    )
    return ComposedMetadata(
        title=title,
        description=description,
        tags=tags,
        playlists=metadata.playlists,
        title_base=title_base,
        title_sequence=sequence,
    )
