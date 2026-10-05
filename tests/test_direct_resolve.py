from __future__ import annotations

import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from types import SimpleNamespace
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from tg_video_relay_bot.downloader import (
    DirectMediaResult,
    DownloadError,
    _direct_mp4_format,
    _direct_source_kind,
    _probe_direct_mp4,
    resolve_direct_media,
)
from tg_video_relay_bot.submit_server import make_handler


class DirectFormatTests(unittest.TestCase):
    def test_only_real_platform_hosts_are_accepted(self) -> None:
        self.assertEqual(_direct_source_kind("https://v.douyin.com/abc/"), "douyin")
        self.assertEqual(_direct_source_kind("https://www.tiktok.com/@a/video/123"), "tiktok")
        self.assertEqual(_direct_source_kind("https://youtu.be/abc"), "youtube")
        self.assertEqual(_direct_source_kind("https://www.youtube.com/shorts/abc"), "youtube")
        self.assertEqual(_direct_source_kind("https://x.com/user/status/123"), "twitter")
        self.assertEqual(_direct_source_kind("https://www.instagram.com/reel/abc/"), "instagram")
        self.assertEqual(_direct_source_kind("https://www.pornhub.com/view_video.php?viewkey=abc"), "pornhub")
        self.assertIsNone(_direct_source_kind("https://tiktok.com.evil.test/video/123"))
        self.assertIsNone(_direct_source_kind("https://youtube.com.evil.test/watch?v=abc"))
        self.assertIsNone(_direct_source_kind("javascript:https://youtube.com/watch?v=abc"))
        self.assertIsNone(_direct_source_kind("https://example.test/video.mp4"))

    def test_prefers_iphone_compatible_progressive_mp4(self) -> None:
        info = {"formats": [
            {"url": "https://cdn.example.test/hevc.mp4", "ext": "mp4", "protocol": "https", "vcodec": "h265", "acodec": "aac", "height": 1080},
            {"url": "https://cdn.example.test/avc.mp4", "ext": "mp4", "protocol": "https", "vcodec": "h264", "acodec": "aac", "height": 720},
            {"url": "https://cdn.example.test/silent.mp4", "ext": "mp4", "protocol": "https", "vcodec": "h264", "acodec": "none", "height": 2160},
            {"url": "http://cdn.example.test/insecure.mp4", "ext": "mp4", "protocol": "http", "vcodec": "h264", "acodec": "aac", "height": 2160},
            {"url": "https://127.0.0.1/private.mp4", "ext": "mp4", "protocol": "https", "vcodec": "h264", "acodec": "aac", "height": 2160},
        ]}
        self.assertEqual(_direct_mp4_format(info)["url"], "https://cdn.example.test/avc.mp4")

    @patch("tg_video_relay_bot.downloader.requests.Session")
    def test_probe_rejects_error_page_disguised_as_video(self, session_class) -> None:
        response = session_class.return_value.__enter__.return_value.get.return_value.__enter__.return_value
        response.is_redirect = False
        response.status_code = 403
        response.iter_content.return_value = iter([b"<HTML>not a video"])
        self.assertFalse(_probe_direct_mp4("https://cdn.example.test/video.mp4", {}))

        response.status_code = 206
        response.iter_content.return_value = iter([b"\x00\x00\x00\x18ftypisom"])
        self.assertTrue(_probe_direct_mp4("https://cdn.example.test/video.mp4", {}))

    @patch("tg_video_relay_bot.downloader._sync_cookies_or_fail")
    @patch("tg_video_relay_bot.downloader._probe_direct_mp4", return_value=True)
    @patch("tg_video_relay_bot.downloader._base_ytdlp_options", return_value={})
    @patch("tg_video_relay_bot.downloader._request_profiles", return_value=[("default", None)])
    @patch("tg_video_relay_bot.downloader.yt_dlp.YoutubeDL")
    def test_resolve_strips_sensitive_headers(self, ydl_class, _profiles, _options, probe, _sync) -> None:
        ydl_class.return_value.__enter__.return_value.extract_info.return_value = {
            "formats": [{
                "url": "https://cdn.example.test/video.mp4", "ext": "mp4", "protocol": "https",
                "vcodec": "h264", "acodec": "aac", "height": 720, "format_id": "h264-720",
                "http_headers": {"Referer": "https://www.tiktok.com/", "Cookie": "private", "Authorization": "secret"},
            }],
        }
        result = resolve_direct_media("https://www.tiktok.com/@a/video/123", SimpleNamespace())
        self.assertEqual(result.url, "https://cdn.example.test/video.mp4")
        self.assertEqual(result.headers, {"Referer": "https://www.tiktok.com/"})
        self.assertEqual(result.height, 720)
        probe.assert_called_once()

    @patch("tg_video_relay_bot.downloader._sync_cookies_or_fail")
    @patch("tg_video_relay_bot.downloader._probe_direct_mp4", return_value=False)
    @patch("tg_video_relay_bot.downloader._base_ytdlp_options", return_value={})
    @patch("tg_video_relay_bot.downloader._request_profiles", return_value=[("default", None)])
    @patch("tg_video_relay_bot.downloader.yt_dlp.YoutubeDL")
    def test_unreadable_media_is_rejected(self, ydl_class, _profiles, _options, _probe, _sync) -> None:
        ydl_class.return_value.__enter__.return_value.extract_info.return_value = {
            "formats": [{
                "url": "https://cdn.example.test/video.mp4", "ext": "mp4", "protocol": "https",
                "vcodec": "h264", "acodec": "aac", "height": 720,
            }],
        }
        with self.assertRaisesRegex(DownloadError, "cannot be read directly"):
            resolve_direct_media("https://www.tiktok.com/@a/video/123", SimpleNamespace())

    @patch("tg_video_relay_bot.downloader._sync_cookies_or_fail")
    @patch("tg_video_relay_bot.downloader._probe_direct_mp4", return_value=True)
    @patch("tg_video_relay_bot.downloader._youtube_auto_download_client_sets", return_value=[[], ["web"]])
    @patch("tg_video_relay_bot.downloader._base_ytdlp_options", return_value={})
    @patch("tg_video_relay_bot.downloader._request_profiles", return_value=[("default", None)])
    @patch("tg_video_relay_bot.downloader.yt_dlp.YoutubeDL")
    def test_youtube_tries_player_client_fallbacks(
        self, ydl_class, _profiles, options, _clients, _probe, _sync
    ) -> None:
        ydl_class.return_value.__enter__.return_value.extract_info.side_effect = [
            {"formats": []},
            {"formats": [{
                "url": "https://cdn.example.test/video.mp4", "ext": "mp4", "protocol": "https",
                "vcodec": "h264", "acodec": "aac", "height": 720,
            }]},
        ]
        result = resolve_direct_media("https://youtu.be/abc", SimpleNamespace())
        self.assertEqual(result.height, 720)
        self.assertEqual(options.call_args_list[0].kwargs["youtube_clients"], [])
        self.assertEqual(options.call_args_list[1].kwargs["youtube_clients"], ["web"])


class ResolveApiTests(unittest.TestCase):
    def setUp(self) -> None:
        settings = SimpleNamespace(submit_api_secret="test-secret")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(settings, object()))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.endpoint = f"http://127.0.0.1:{self.server.server_port}/resolve"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def request(self, secret: str = "test-secret") -> tuple[int, dict]:
        body = urlencode({"secret": secret, "url": "https://v.douyin.com/abc/"}).encode()
        request = Request(self.endpoint, data=body, method="POST")
        try:
            with urlopen(request, timeout=3) as response:
                return response.status, json.load(response)
        except HTTPError as exc:
            return exc.code, json.load(exc)

    @patch("tg_video_relay_bot.submit_server.resolve_direct_media")
    def test_success(self, resolver) -> None:
        resolver.return_value = DirectMediaResult("https://cdn.example.test/video.mp4", {}, "h264", 720)
        status, payload = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(payload["mode"], "direct")
        self.assertEqual(payload["url"], "https://cdn.example.test/video.mp4")

    @patch("tg_video_relay_bot.submit_server.resolve_direct_media")
    def test_extractor_failure_returns_fallback(self, resolver) -> None:
        resolver.side_effect = DownloadError("login required")
        status, payload = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(payload["mode"], "server")
        self.assertFalse(payload["ok"])

    def test_bad_secret(self) -> None:
        status, payload = self.request("wrong")
        self.assertEqual(status, 403)
        self.assertEqual(payload["error"], "bad_secret")


if __name__ == "__main__":
    unittest.main()
