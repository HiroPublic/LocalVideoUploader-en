from __future__ import annotations

import httplib2
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from googleapiclient.errors import HttpError

from iphoto2youtube_cli.exceptions import YouTubeApiError
from iphoto2youtube_cli.models import ComposedMetadata, VideoMetadataInput
from iphoto2youtube_cli.services.youtube import YouTubeUploadService, _classify_youtube_error, fetch_video_verification


class DummyRequest:
    def __init__(self, response: dict[str, object]) -> None:
        self.response = response

    def execute(self) -> dict[str, object]:
        return self.response


class DummyPlaylistResource:
    def __init__(self) -> None:
        self.insert_body: dict[str, object] | None = None
        self.list_responses: list[dict[str, object]] = [{"items": []}]

    def list(self, **_: object) -> DummyRequest:
        response = self.list_responses.pop(0) if self.list_responses else {"items": []}
        return DummyRequest(response)

    def insert(self, **kwargs: object) -> DummyRequest:
        self.insert_body = dict(kwargs)
        return DummyRequest({"id": "playlist123"})


class DummyPlaylistItemsResource:
    def __init__(self) -> None:
        self.list_responses: list[dict[str, object]] = []
        self.insert_calls: list[dict[str, object]] = []
        self.delete_calls: list[dict[str, object]] = []

    def list(self, **_: object) -> DummyRequest:
        response = self.list_responses.pop(0) if self.list_responses else {"items": []}
        return DummyRequest(response)

    def insert(self, **kwargs: object) -> DummyRequest:
        self.insert_calls.append(dict(kwargs))
        return DummyRequest({"id": "new-playlist-item"})

    def delete(self, **kwargs: object) -> DummyRequest:
        self.delete_calls.append(dict(kwargs))
        return DummyRequest({})


class DummyVideosResource:
    def __init__(self) -> None:
        self.list_response: dict[str, object] = {"items": []}
        self.update_body: dict[str, object] | None = None

    def list(self, **_: object) -> DummyRequest:
        return DummyRequest(self.list_response)

    def update(self, **kwargs: object) -> DummyRequest:
        self.update_body = dict(kwargs)
        return DummyRequest({"id": "video123"})


class DummyYoutube:
    def __init__(self) -> None:
        self.playlist_resource = DummyPlaylistResource()
        self.playlist_items_resource = DummyPlaylistItemsResource()
        self.videos_resource = DummyVideosResource()

    def playlists(self) -> DummyPlaylistResource:
        return self.playlist_resource

    def playlistItems(self) -> DummyPlaylistItemsResource:
        return self.playlist_items_resource

    def videos(self) -> DummyVideosResource:
        return self.videos_resource


class YouTubeServiceTest(unittest.TestCase):
    def test_ensure_playlist_uses_requested_privacy(self) -> None:
        service = YouTubeUploadService.__new__(YouTubeUploadService)
        service.youtube = DummyYoutube()
        service._playlist_cache = {}
        service._playlist_cache_populated = False
        service._playlist_api_blocked = False

        playlist_id = service.ensure_playlist("[散歩] 自宅_花見", "unlisted")

        self.assertEqual(playlist_id, "playlist123")
        insert_body = service.youtube.playlist_resource.insert_body
        self.assertIsNotNone(insert_body)
        self.assertEqual(insert_body["body"]["status"]["privacyStatus"], "unlisted")

    def test_ensure_playlist_uses_cached_results_within_batch(self) -> None:
        service = YouTubeUploadService.__new__(YouTubeUploadService)
        service.youtube = DummyYoutube()
        service._playlist_cache = {}
        service._playlist_cache_populated = False
        service._playlist_api_blocked = False
        service.youtube.playlist_resource.list_responses = [
            {
                "items": [
                    {"id": "playlist123", "snippet": {"title": "[散歩] 自宅_花見"}},
                ]
            }
        ]

        first = service.ensure_playlist("[散歩] 自宅_花見", "private")
        second = service.ensure_playlist("[散歩] 自宅_花見", "private")

        self.assertEqual(first, "playlist123")
        self.assertEqual(second, "playlist123")
        self.assertIsNone(service.youtube.playlist_resource.insert_body)
        self.assertEqual(service.youtube.playlist_resource.list_responses, [])

    def test_classify_youtube_error_marks_quota(self) -> None:
        response = httplib2.Response({"status": "403"})
        error = HttpError(
            response,
            b'{"error":{"errors":[{"reason":"quotaExceeded"}],"code":403,"message":"quotaExceeded"}}',
        )

        classified = _classify_youtube_error(error, operation="videos.insert")

        self.assertEqual(classified.category, "quota")
        self.assertFalse(classified.retryable)
        self.assertEqual(classified.status_code, 403)

    def test_classify_youtube_error_includes_invalid_request_detail(self) -> None:
        response = httplib2.Response({"status": "400"})
        error = HttpError(
            response,
            b'{"error":{"errors":[{"reason":"invalidTags"}],"code":400,"message":"The request metadata specifies invalid video metadata."}}',
        )

        classified = _classify_youtube_error(error, operation="videos.insert")

        self.assertEqual(classified.category, "invalid_request")
        self.assertIn("invalidTags", str(classified))
        self.assertIn("invalid video metadata", str(classified))

    def test_classify_youtube_error_marks_upload_limit(self) -> None:
        response = httplib2.Response({"status": "400"})
        error = HttpError(
            response,
            b'{"error":{"errors":[{"reason":"uploadLimitExceeded"}],"code":400,"message":"The user has exceeded the number of videos they may upload."}}',
        )

        classified = _classify_youtube_error(error, operation="videos.insert")

        self.assertEqual(classified.category, "upload_limit")
        self.assertIn("アップロード上限", str(classified))

    def test_sync_video_metadata_updates_video_and_playlists(self) -> None:
        service = YouTubeUploadService.__new__(YouTubeUploadService)
        service.youtube = DummyYoutube()
        service._playlist_cache = {}
        service._playlist_cache_populated = False
        service._playlist_api_blocked = False
        service.youtube.videos_resource.list_response = {
            "items": [
                {
                    "id": "video123",
                    "snippet": {
                        "title": "old",
                        "description": "old-desc",
                        "tags": ["old"],
                        "categoryId": "22",
                    },
                    "status": {"privacyStatus": "private"},
                }
            ]
        }
        service.youtube.playlist_resource.list_responses = [
            {
                "items": [
                    {"id": "playlist-old", "snippet": {"title": "Old Playlist"}},
                    {"id": "playlist-keep", "snippet": {"title": "Keep Playlist"}},
                ]
            },
            {"items": []},
        ]
        service.youtube.playlist_items_resource.list_responses = [
            {
                "items": [
                    {"id": "pli-old", "snippet": {"resourceId": {"videoId": "video123"}}},
                ]
            },
            {
                "items": [
                    {"id": "pli-keep", "snippet": {"resourceId": {"videoId": "video123"}}},
                ]
            },
        ]

        summary = service.sync_video_metadata(
            video_id="video123",
            title="new-title",
            description="new-description",
            tags=["#tagA", "#tagB"],
            privacy_status="private",
            playlists=["Keep Playlist", "New Playlist"],
        )

        update_body = service.youtube.videos_resource.update_body
        self.assertIsNotNone(update_body)
        self.assertEqual(update_body["body"]["snippet"]["title"], "new-title")
        self.assertEqual(update_body["body"]["snippet"]["description"], "new-description")
        self.assertEqual(update_body["body"]["snippet"]["tags"], ["tagA", "tagB"])
        self.assertEqual(service.youtube.playlist_resource.insert_body["body"]["snippet"]["title"], "New Playlist")
        self.assertEqual(len(service.youtube.playlist_items_resource.insert_calls), 1)
        self.assertEqual(len(service.youtube.playlist_items_resource.delete_calls), 1)
        self.assertEqual(summary["added_playlists"], ["New Playlist"])
        self.assertEqual(summary["removed_playlists"], ["Old Playlist"])

    def test_fetch_video_verification_continues_when_playlist_lookup_hits_quota(self) -> None:
        youtube = DummyYoutube()
        youtube.videos_resource.list_response = {
            "items": [
                {
                    "id": "video123",
                    "snippet": {"title": "sample", "description": "desc"},
                    "status": {"privacyStatus": "private", "uploadStatus": "processed"},
                    "processingDetails": {"processingStatus": "succeeded"},
                    "fileDetails": {},
                }
            ]
        }
        with patch("iphoto2youtube_cli.services.youtube._build_youtube_client", return_value=youtube):
            with patch(
                "iphoto2youtube_cli.services.youtube._execute_request",
                side_effect=lambda request, operation: request.execute(),
            ):
                with patch(
                    "iphoto2youtube_cli.services.youtube._find_playlist_memberships_for_video",
                    side_effect=YouTubeApiError(
                        "quota",
                        operation="playlistItems.list",
                        category="quota",
                        retryable=False,
                        status_code=403,
                        reason="quotaExceeded",
                    ),
                ):
                    payload = fetch_video_verification(object(), "video123")

        self.assertEqual(payload["youtube_video_id"], "video123")
        self.assertEqual(payload["playlists"], [])
        self.assertIn("playlist_lookup_error", payload)

    def test_upload_video_stops_playlist_calls_after_quota(self) -> None:
        service = YouTubeUploadService.__new__(YouTubeUploadService)
        service.youtube = DummyYoutube()
        service._playlist_cache = {}
        service._playlist_cache_populated = False
        service._playlist_api_blocked = False

        metadata = VideoMetadataInput(
            video_path=Path("/tmp/sample.mov"),
            capture_datetime=datetime(2026, 4, 12, 7, 0, 0),
            file_size_bytes=123,
            duration_seconds=10,
            width=1920,
            height=1080,
            playlists=["Insta360", "Backup"],
        )
        composed = ComposedMetadata(
            title="sample",
            description="desc",
            tags=["#tag"],
            playlists=["Insta360", "Backup"],
            title_base="sample",
            title_sequence=0,
        )

        class DummyInsertRequest:
            def next_chunk(self):
                return None, {"id": "video123"}

        ensure_calls: list[str] = []

        def fake_ensure_playlist(name: str, privacy_status: str) -> str:
            ensure_calls.append(name)
            if name == "Insta360":
                raise YouTubeApiError(
                    "quota",
                    operation="playlists.list",
                    category="quota",
                    retryable=False,
                    status_code=403,
                    reason="quotaExceeded",
                )
            return f"{name}-id"

        with patch("googleapiclient.http.MediaFileUpload"):
            with patch.object(service.youtube.videos_resource, "insert", return_value=DummyInsertRequest(), create=True):
                with patch.object(service, "ensure_playlist", side_effect=fake_ensure_playlist):
                    with patch.object(service, "attach_video_to_playlist") as attach_mock:
                        result = service.upload_video(metadata, composed)

        self.assertTrue(result.success)
        self.assertEqual(result.youtube_video_id, "video123")
        self.assertEqual(ensure_calls, ["Insta360"])
        self.assertEqual(result.playlist_ids, {})
        attach_mock.assert_not_called()
        self.assertTrue(service._playlist_api_blocked)
