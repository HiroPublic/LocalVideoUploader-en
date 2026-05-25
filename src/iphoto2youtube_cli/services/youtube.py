from __future__ import annotations

from datetime import datetime, timedelta
import json
from pathlib import Path

from ..exceptions import UploadError, YouTubeApiError
from ..models import ChannelInfo, ComposedMetadata, UploadResult, VideoMetadataInput

YOUTUBE_API_DAILY_QUOTA_LIMIT = 50_000
YOUTUBE_API_QUOTA_COSTS = {
    "channels.list": 1,
    "videos.list": 1,
    "playlists.list": 1,
    "playlistItems.list": 1,
    "videos.insert": 100,
    "playlists.insert": 50,
    "playlistItems.insert": 50,
    "videos.update": 50,
    "playlistItems.delete": 50,
    "videos.delete": 50,
}


def _quota_logger_kwargs(quota_logger):
    return {"quota_logger": quota_logger} if quota_logger is not None else {}


def _format_upload_limit_retry_estimate(now: datetime | None = None) -> str:
    current = now or datetime.now().astimezone()
    if current.tzinfo is None:
        current = current.astimezone()

    retry_at = current + timedelta(hours=24)
    if retry_at.minute != 0 or retry_at.second != 0 or retry_at.microsecond != 0:
        retry_at = retry_at.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)

    return retry_at.strftime("%Y-%m-%d %H:%M %Z")


def fetch_authenticated_channel(credentials, quota_logger=None) -> ChannelInfo:
    try:
        from googleapiclient.discovery import build
    except ImportError as exc:
        raise UploadError(
            "Google API クライアントが未導入です。`pip install -e .` を実行してください。"
        ) from exc

    youtube = build("youtube", "v3", credentials=credentials)
    response = _execute_request(
        youtube.channels().list(part="snippet", mine=True),
        operation="channels.list",
        **_quota_logger_kwargs(quota_logger),
    )
    items = response.get("items", [])
    if not items:
        raise UploadError("認証済みチャンネル情報を取得できませんでした。")
    item = items[0]
    snippet = item.get("snippet", {})
    return ChannelInfo(
        channel_id=item.get("id", ""),
        title=snippet.get("title", ""),
        handle=snippet.get("customUrl", ""),
    )


def _build_youtube_client(credentials):
    try:
        from googleapiclient.discovery import build
    except ImportError as exc:
        raise UploadError(
            "Google API クライアントが未導入です。`pip install -e .` を実行してください。"
        ) from exc
    return build("youtube", "v3", credentials=credentials)


def fetch_video_verification(credentials, video_id: str, quota_logger=None) -> dict[str, object]:
    youtube = _build_youtube_client(credentials)
    response = _execute_request(
        youtube.videos().list(
            part="snippet,status,processingDetails,fileDetails",
            id=video_id,
        ),
        operation="videos.list",
        **_quota_logger_kwargs(quota_logger),
    )
    items = response.get("items", [])
    if not items:
        raise UploadError(f"YouTube 上に動画が見つかりません: {video_id}")

    item = items[0]
    snippet = item.get("snippet", {})
    status = item.get("status", {})
    processing = item.get("processingDetails", {})
    file_details = item.get("fileDetails", {})
    video_streams = file_details.get("videoStreams", [])
    first_stream = video_streams[0] if video_streams else {}

    playlist_lookup_error = ""
    try:
        playlist_memberships = _find_playlist_memberships_for_video(
            youtube,
            video_id,
            quota_logger=quota_logger,
        )
    except YouTubeApiError as exc:
        if exc.category in {"quota", "rate_limit"}:
            playlist_memberships = []
            playlist_lookup_error = str(exc)
        else:
            raise
    playlists = [{"id": item["playlist_id"], "title": item["title"]} for item in playlist_memberships]
    payload = {
        "youtube_video_id": item.get("id", ""),
        "title": snippet.get("title", ""),
        "description": snippet.get("description", ""),
        "tags": snippet.get("tags", []),
        "privacy_status": status.get("privacyStatus", ""),
        "upload_status": status.get("uploadStatus", ""),
        "processing_status": processing.get("processingStatus", ""),
        "channel_id": snippet.get("channelId", ""),
        "channel_title": snippet.get("channelTitle", ""),
        "published_at": snippet.get("publishedAt", ""),
        "thumbnails": list((snippet.get("thumbnails") or {}).keys()),
        "file_name": file_details.get("fileName", ""),
        "file_size_bytes": file_details.get("fileSize", ""),
        "resolution": {
            "width_pixels": first_stream.get("widthPixels"),
            "height_pixels": first_stream.get("heightPixels"),
        },
        "playlists": playlists,
    }
    if playlist_lookup_error:
        payload["playlist_lookup_error"] = playlist_lookup_error
    return payload


def _find_playlist_memberships_for_video(youtube, video_id: str, quota_logger=None) -> list[dict[str, str]]:
    playlists: list[dict[str, str]] = []
    next_token = None
    while True:
        response = _execute_request(
            youtube.playlists().list(
                part="snippet",
                mine=True,
                maxResults=50,
                pageToken=next_token,
            ),
            operation="playlists.list",
            **_quota_logger_kwargs(quota_logger),
        )
        for item in response.get("items", []):
            playlist_id = item.get("id")
            playlist_title = item.get("snippet", {}).get("title", "")
            if not playlist_id:
                continue
            playlist_item_id = _find_playlist_item_id(youtube, playlist_id, video_id, quota_logger=quota_logger)
            if playlist_item_id:
                playlists.append(
                    {"playlist_id": playlist_id, "title": playlist_title, "playlist_item_id": playlist_item_id}
                )
        next_token = response.get("nextPageToken")
        if not next_token:
            break
    return playlists


def _find_playlist_item_id(youtube, playlist_id: str, video_id: str, quota_logger=None) -> str | None:
    next_token = None
    while True:
        response = _execute_request(
            youtube.playlistItems().list(
                part="snippet",
                playlistId=playlist_id,
                maxResults=50,
                pageToken=next_token,
            ),
            operation="playlistItems.list",
            **_quota_logger_kwargs(quota_logger),
        )
        for item in response.get("items", []):
            resource = item.get("snippet", {}).get("resourceId", {})
            if resource.get("videoId") == video_id:
                return str(item.get("id") or "")
        next_token = response.get("nextPageToken")
        if not next_token:
            break
    return None


class YouTubeUploadService:
    def __init__(self, credentials, quota_logger=None, progress_callback=None) -> None:
        self.youtube = _build_youtube_client(credentials)
        self.quota_logger = quota_logger
        self.progress_callback = progress_callback
        self._playlist_cache: dict[str, str] = {}
        self._playlist_cache_populated = False
        self._playlist_api_blocked = False

    def upload_video(self, metadata: VideoMetadataInput, composed: ComposedMetadata) -> UploadResult:
        try:
            from googleapiclient.http import MediaFileUpload
        except ImportError as exc:
            raise UploadError(
                "Google API クライアントが未導入です。`pip install -e .` を実行してください。"
            ) from exc

        body = {
            "snippet": {
                "title": composed.title,
                "description": composed.description,
                "tags": [tag.lstrip("#") for tag in composed.tags],
            },
            "status": {"privacyStatus": metadata.privacy_status},
        }
        media = MediaFileUpload(str(metadata.video_path), resumable=True)
        request = self.youtube.videos().insert(
            part="snippet,status",
            body=body,
            media_body=media,
        )
        response = self._execute_resumable_request(
            request,
            operation="videos.insert",
            metadata=metadata,
        )
        video_id = response.get("id")
        if not video_id:
            raise UploadError("YouTube API から動画 ID を取得できませんでした。")

        playlist_ids: dict[str, str] = {}
        for playlist_name in composed.playlists:
            if self._playlist_api_blocked:
                break
            try:
                playlist_id = self.ensure_playlist(playlist_name, metadata.playlist_privacy_status)
                self.attach_video_to_playlist(video_id, playlist_id)
                playlist_ids[playlist_name] = playlist_id
            except YouTubeApiError as exc:
                if exc.category in {"quota", "rate_limit"}:
                    self._playlist_api_blocked = True
                    # Keep the upload successful and defer playlist assignment to a later retry.
                    continue
                raise

        uploaded_at = datetime.now()
        return UploadResult(
            success=True,
            youtube_video_id=video_id,
            youtube_video_url=f"https://www.youtube.com/watch?v={video_id}",
            uploaded_at=uploaded_at,
            privacy_status=metadata.privacy_status,
            upload_status="success",
            playlist_ids=playlist_ids,
        )

    def ensure_playlist(self, playlist_name: str, privacy_status: str) -> str:
        cached = self._playlist_cache.get(playlist_name)
        if cached:
            return cached

        self._populate_playlist_cache()
        cached = self._playlist_cache.get(playlist_name)
        if cached:
            return cached

        try:
            create_response = _execute_request(
                self.youtube.playlists().insert(
                    part="snippet,status",
                    body={
                        "snippet": {"title": playlist_name},
                        "status": {"privacyStatus": privacy_status},
                    },
                ),
                operation="playlists.insert",
                **_quota_logger_kwargs(getattr(self, "quota_logger", None)),
            )
        except YouTubeApiError as exc:
            if exc.category in {"quota", "rate_limit"}:
                self._playlist_api_blocked = True
            raise
        playlist_id = create_response.get("id")
        if not playlist_id:
            raise UploadError(f"プレイリストの作成に失敗しました: {playlist_name}")
        self._playlist_cache[playlist_name] = str(playlist_id)
        return playlist_id

    def attach_video_to_playlist(self, video_id: str, playlist_id: str) -> None:
        try:
            _execute_request(
                self.youtube.playlistItems().insert(
                    part="snippet",
                    body={
                        "snippet": {
                            "playlistId": playlist_id,
                            "resourceId": {"kind": "youtube#video", "videoId": video_id},
                        }
                    },
                ),
                operation="playlistItems.insert",
                **_quota_logger_kwargs(getattr(self, "quota_logger", None)),
            )
        except YouTubeApiError as exc:
            if exc.category in {"quota", "rate_limit"}:
                self._playlist_api_blocked = True
            raise

    def delete_video(self, video_id: str) -> None:
        _execute_request(
            self.youtube.videos().delete(id=video_id),
            operation="videos.delete",
            **_quota_logger_kwargs(getattr(self, "quota_logger", None)),
        )

    def sync_video_metadata(
        self,
        *,
        video_id: str,
        title: str,
        description: str,
        tags: list[str],
        privacy_status: str,
        playlists: list[str],
        playlist_privacy_status: str = "private",
    ) -> dict[str, object]:
        video_state = _execute_request(
            self.youtube.videos().list(part="snippet,status", id=video_id),
            operation="videos.list",
            **_quota_logger_kwargs(getattr(self, "quota_logger", None)),
        )
        items = video_state.get("items", [])
        if not items:
            raise UploadError(f"YouTube 上に動画が見つかりません: {video_id}")

        item = items[0]
        snippet = dict(item.get("snippet", {}) or {})
        status = dict(item.get("status", {}) or {})
        snippet["title"] = title
        snippet["description"] = description
        snippet["tags"] = [tag.lstrip("#") for tag in tags]
        status["privacyStatus"] = privacy_status

        _execute_request(
            self.youtube.videos().update(
                part="snippet,status",
                body={
                    "id": video_id,
                    "snippet": snippet,
                    "status": status,
                },
            ),
            operation="videos.update",
            **_quota_logger_kwargs(getattr(self, "quota_logger", None)),
        )

        desired_playlists = list(dict.fromkeys(playlists))
        current_memberships = _find_playlist_memberships_for_video(
            self.youtube,
            video_id,
            quota_logger=getattr(self, "quota_logger", None),
        )
        current_by_title = {item["title"]: item for item in current_memberships}
        desired_set = set(desired_playlists)
        current_set = set(current_by_title.keys())

        added_playlists: list[str] = []
        removed_playlists: list[str] = []

        for playlist_name in desired_playlists:
            if playlist_name in current_set:
                continue
            playlist_id = self.ensure_playlist(playlist_name, playlist_privacy_status)
            self.attach_video_to_playlist(video_id, playlist_id)
            added_playlists.append(playlist_name)

        for playlist_name, membership in current_by_title.items():
            if playlist_name in desired_set:
                continue
            playlist_item_id = membership.get("playlist_item_id")
            if playlist_item_id:
                _execute_request(
                    self.youtube.playlistItems().delete(id=playlist_item_id),
                    operation="playlistItems.delete",
                    **_quota_logger_kwargs(getattr(self, "quota_logger", None)),
                )
                removed_playlists.append(playlist_name)

        return {
            "video_id": video_id,
            "updated_fields": ["title", "description", "tags", "privacy_status", "playlists"],
            "added_playlists": added_playlists,
            "removed_playlists": removed_playlists,
        }

    def _execute_resumable_request(self, request, *, operation: str, metadata: VideoMetadataInput | None = None):
        response = None
        recorded = False
        progress_callback = getattr(self, "progress_callback", None)
        video_path = str(metadata.video_path) if metadata else ""
        file_name = Path(video_path).name if video_path else ""
        while response is None:
            try:
                status, response = request.next_chunk()
                if status is not None and progress_callback is not None:
                    progress_callback(
                        {
                            "event": "youtube_upload_progress",
                            "operation": operation,
                            "video_path": video_path,
                            "file_name": file_name,
                            "progress": float(status.progress()),
                        }
                    )
            except Exception as exc:
                classified = _classify_youtube_error(exc, operation=operation)
                if not recorded and classified.status_code is not None:
                    _record_quota_usage(getattr(self, "quota_logger", None), operation)
                    recorded = True
                raise classified from exc
        if not recorded:
            _record_quota_usage(getattr(self, "quota_logger", None), operation)
        if progress_callback is not None:
            progress_callback(
                {
                    "event": "youtube_upload_progress",
                    "operation": operation,
                    "video_path": video_path,
                    "file_name": file_name,
                    "progress": 1.0,
                }
            )
        return response

    def _populate_playlist_cache(self) -> None:
        if self._playlist_cache_populated or self._playlist_api_blocked:
            return
        try:
            search_response = _execute_request(
                self.youtube.playlists().list(part="snippet,status", mine=True, maxResults=50),
                operation="playlists.list",
                **_quota_logger_kwargs(getattr(self, "quota_logger", None)),
            )
        except YouTubeApiError as exc:
            if exc.category in {"quota", "rate_limit"}:
                self._playlist_api_blocked = True
            raise

        for item in search_response.get("items", []):
            title = item.get("snippet", {}).get("title")
            playlist_id = item.get("id")
            if title and playlist_id:
                self._playlist_cache[str(title)] = str(playlist_id)
        self._playlist_cache_populated = True


def _execute_request(request, *, operation: str, quota_logger=None):
    try:
        response = request.execute()
        _record_quota_usage(quota_logger, operation)
        return response
    except Exception as exc:
        classified = _classify_youtube_error(exc, operation=operation)
        if classified.status_code is not None:
            _record_quota_usage(quota_logger, operation)
        raise classified from exc


def _record_quota_usage(quota_logger, operation: str) -> None:
    if quota_logger is None:
        return
    quota_cost = YOUTUBE_API_QUOTA_COSTS.get(operation)
    if quota_cost is None:
        return
    quota_logger.record_api_quota_usage(operation=operation, quota_cost=quota_cost)


def _extract_error_detail(exc: Exception) -> str:
    content = getattr(exc, "content", b"") or b""
    if not content:
        return ""
    try:
        payload = json.loads(content.decode("utf-8", errors="ignore"))
        error_payload = payload.get("error", {}) if isinstance(payload, dict) else {}
        error_message = str(error_payload.get("message") or "").strip()
        errors = error_payload.get("errors") or []
        first_reason = str(errors[0].get("reason") or "").strip() if errors else ""
        return " / ".join(part for part in [first_reason, error_message] if part)
    except Exception:
        return ""


def _classify_youtube_error(exc: Exception, *, operation: str) -> YouTubeApiError:
    try:
        from googleapiclient.errors import HttpError
    except ImportError:
        HttpError = None

    if HttpError and isinstance(exc, HttpError):
        status_code = getattr(getattr(exc, "resp", None), "status", None)
        reason = ""
        try:
            payload = exc.error_details if getattr(exc, "error_details", None) else []
            if payload and isinstance(payload, list):
                reason = str(payload[0].get("reason") or "")
        except Exception:
            reason = ""
        if not reason:
            content = getattr(exc, "content", b"") or b""
            text = content.decode("utf-8", errors="ignore")
            reason = text[:200]
        category = "unknown"
        retryable = False
        message = f"YouTube API エラー: {operation}"
        detail = _extract_error_detail(exc)
        if status_code in {401}:
            category = "auth"
            message = f"YouTube 認証が無効です: {operation}. `auth-login` をやり直してください。"
        elif status_code in {403} and ("quota" in reason.lower() or "dailyLimitExceeded" in reason):
            category = "quota"
            suffix = f" 詳細: {detail}" if detail else ""
            message = f"YouTube API クォータ不足です: {operation}. 日次上限の可能性があります。{suffix}"
        elif status_code in {403} and ("rateLimit" in reason or "userRateLimitExceeded" in reason):
            category = "rate_limit"
            retryable = True
            suffix = f" 詳細: {detail}" if detail else ""
            message = f"YouTube API のレート制限です: {operation}. 少し待って再試行してください。{suffix}"
        elif status_code in {403}:
            category = "permission"
            suffix = f" 詳細: {detail}" if detail else ""
            message = f"YouTube API 権限エラーです: {operation}. 認証アカウントと権限を確認してください。{suffix}"
        elif status_code in {404}:
            category = "not_found"
            message = f"YouTube API で対象が見つかりません: {operation}."
        elif status_code in {400} and "uploadLimitExceeded" in reason:
            category = "upload_limit"
            suffix = f" 詳細: {detail}" if detail else ""
            retry_estimate = _format_upload_limit_retry_estimate()
            message = (
                f"YouTube チャンネルの日次アップロード本数制限に達しました: {operation}. "
                f"24時間後（推定日時: {retry_estimate} 以降）に再試行してください。{suffix}"
            )
        elif status_code in {400}:
            category = "invalid_request"
            suffix = f" 詳細: {detail}" if detail else ""
            message = f"YouTube API へのリクエストが不正です: {operation}. 入力値を確認してください。{suffix}"
        elif status_code and status_code >= 500:
            category = "server"
            retryable = True
            message = f"YouTube API サーバーエラーです: {operation}. 再試行可能です。"
        return YouTubeApiError(
            message,
            operation=operation,
            category=category,
            retryable=retryable,
            status_code=status_code,
            reason=reason,
        )

    message = f"YouTube API 呼び出しに失敗しました: {operation}."
    category = "network"
    retryable = True
    lower = str(exc).lower()
    if "timed out" in lower or "connection" in lower or "network" in lower:
        message = f"ネットワークエラーです: {operation}. 接続を確認して再試行してください。"
    return YouTubeApiError(
        message,
        operation=operation,
        category=category,
        retryable=retryable,
        reason=str(exc),
    )
