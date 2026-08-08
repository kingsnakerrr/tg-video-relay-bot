from __future__ import annotations

from email import policy
from email.parser import BytesParser
import json
import logging
import mimetypes
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock, Thread
from time import monotonic
from typing import Any
from urllib.parse import parse_qs, quote, urlparse

from .config import Settings
from .downloader import cleanup_download, download_video
from .formats import format_for_max_height
from .jobs import JobQueue, VideoJob
from .links import extract_urls


MAX_BODY_BYTES = 64 * 1024
SUBMIT_DEDUP_SECONDS = 8.0


class SubmitServerError(RuntimeError):
    pass


class LocalDownloadError(RuntimeError):
    pass


def _is_youtube_url(url: str) -> bool:
    lowered = url.lower()
    return "youtube.com" in lowered or "youtu.be" in lowered


def _highest_download_choice(url: str, settings: Settings) -> tuple[str | None, str | None]:
    if not _is_youtube_url(url):
        return None, None
    # Chrome/TG submits should download the best format yt-dlp can actually
    # fetch. Locking a probed YouTube format id can fail when another player
    # client is needed for the real download.
    return None, "highest available"


def _local_download_choice(url: str, settings: Settings) -> tuple[str | None, str | None]:
    if _is_youtube_url(url):
        return format_for_max_height(1080), "iPhone 1080p"
    return None, None


def _needs_iphone_conversion(url: str) -> bool:
    lowered = url.lower()
    return (
        "youtube.com" in lowered
        or "youtu.be" in lowered
        or "instagram.com" in lowered
        or "instagr.am" in lowered
    )

def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    handler.send_header("Access-Control-Allow-Headers", "Content-Type, X-Submit-Secret")
    handler.send_header("Access-Control-Allow-Private-Network", "true")
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.wfile.write(body)


def _empty_response(handler: BaseHTTPRequestHandler, status: int) -> None:
    handler.send_response(status)
    handler.send_header("Content-Length", "0")
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    handler.send_header("Access-Control-Allow-Headers", "Content-Type, X-Submit-Secret")
    handler.send_header("Access-Control-Allow-Private-Network", "true")
    handler.send_header("Connection", "close")
    handler.end_headers()


def _file_response(handler: BaseHTTPRequestHandler, file_path: Path, filename: str) -> None:
    content_type = mimetypes.guess_type(filename)[0] or "video/mp4"
    size = file_path.stat().st_size
    encoded_filename = quote(filename)
    handler.send_response(200)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(size))
    handler.send_header(
        "Content-Disposition",
        f"attachment; filename*=UTF-8''{encoded_filename}",
    )
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    handler.send_header("Access-Control-Allow-Headers", "Content-Type, X-Submit-Secret")
    handler.send_header("Access-Control-Allow-Private-Network", "true")
    handler.send_header("Connection", "close")
    handler.end_headers()
    with file_path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            handler.wfile.write(chunk)


def _iphone_compatible_file(input_path: Path) -> Path:
    output_path = input_path.with_name("iphone-video.mp4")
    command = [
        "ffmpeg",
        "-y",
        "-i",
        str(input_path),
        "-map",
        "0:v:0",
        "-map",
        "0:a?",
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "20",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "128k",
        "-movflags",
        "+faststart",
        "-metadata:s:v:0",
        "rotate=0",
        str(output_path),
    ]
    result = subprocess.run(command, capture_output=True, check=False, text=True)
    if result.returncode != 0 or not output_path.exists():
        raise LocalDownloadError(f"ffmpeg iPhone conversion failed: {result.stderr.strip()[-1200:]}")
    return output_path


def _first(values: dict[str, list[str]], key: str) -> str:
    items = values.get(key, [])
    return items[0] if items else ""


def _normalize_values(values: dict[str, list[str]]) -> dict[str, list[str]]:
    normalized = dict(values)
    for key, items in values.items():
        if "=" not in key:
            continue
        name, embedded_value = key.split("=", 1)
        if name in {"secret", "token", "url", "text", "input"} and embedded_value:
            normalized.setdefault(name, []).append(embedded_value)
        if items:
            normalized.setdefault(name, []).extend(items)
    return normalized


def _parse_multipart(handler: BaseHTTPRequestHandler, raw_body: bytes, content_type: str, length: int) -> dict[str, list[str]]:
    header = (
        f"Content-Type: {content_type}\r\n"
        f"Content-Length: {length}\r\n"
        "MIME-Version: 1.0\r\n\r\n"
    ).encode("utf-8")
    message = BytesParser(policy=policy.default).parsebytes(header + raw_body)
    if not message.is_multipart():
        raise SubmitServerError("Invalid multipart/form-data body.")

    values: dict[str, list[str]] = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        filename = part.get_filename()
        if not name or filename:
            continue
        payload = part.get_content()
        if isinstance(payload, bytes):
            payload = payload.decode(part.get_content_charset() or "utf-8", errors="replace")
        values.setdefault(name, []).append(str(payload))
    return values


def _parse_body(handler: BaseHTTPRequestHandler) -> dict[str, list[str]]:
    length = int(handler.headers.get("Content-Length", "0") or "0")
    if length <= 0:
        return {}
    if length > MAX_BODY_BYTES:
        raise SubmitServerError("Request body is too large.")

    raw_body = handler.rfile.read(length)
    content_type = handler.headers.get("Content-Type", "")
    if "application/json" in content_type:
        payload = json.loads(raw_body.decode("utf-8"))
        return _normalize_values({key: [str(value)] for key, value in payload.items()})
    if "multipart/form-data" in content_type:
        return _normalize_values(_parse_multipart(handler, raw_body, content_type, length))
    return _normalize_values(parse_qs(raw_body.decode("utf-8"), keep_blank_values=True))


def _values_from_query_and_body(handler: BaseHTTPRequestHandler) -> dict[str, list[str]]:
    parsed = urlparse(handler.path)
    values = parse_qs(parsed.query, keep_blank_values=True)
    body_values = _parse_body(handler)
    values.update(body_values)
    return _normalize_values(values)


def _authorized(handler: BaseHTTPRequestHandler, values: dict[str, list[str]], settings: Settings) -> bool:
    if not settings.submit_api_secret:
        return False
    submitted = (
        handler.headers.get("X-Submit-Secret")
        or _first(values, "secret")
        or _first(values, "token")
    )
    submitted = submitted.strip()
    expected = settings.submit_api_secret.strip()
    if submitted != expected:
        logging.warning(
            "submit-api bad secret: submitted_length=%s expected_length=%s",
            len(submitted),
            len(expected),
        )
        return False
    return True


def make_handler(settings: Settings, job_queue: JobQueue) -> type[BaseHTTPRequestHandler]:
    recent_submissions: dict[str, float] = {}
    recent_submissions_lock = Lock()

    class SubmitHandler(BaseHTTPRequestHandler):
        server_version = "TelegramVideoRelaySubmit/1.0"

        def log_message(self, fmt: str, *args: Any) -> None:
            logging.info("submit-api %s - %s", self.address_string(), fmt % args)

        def do_OPTIONS(self) -> None:
            _json_response(self, 200, {"ok": True})

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                _json_response(self, 200, {"ok": True})
                return
            if parsed.path == "/download":
                values = parse_qs(parsed.query, keep_blank_values=True)
                self._download(_normalize_values(values))
                return
            if parsed.path != "/submit":
                _json_response(self, 404, {"ok": False, "error": "not_found"})
                return

            values = parse_qs(parsed.query, keep_blank_values=True)
            self._submit(_normalize_values(values))

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path not in {"/submit", "/download"}:
                _json_response(self, 404, {"ok": False, "error": "not_found"})
                return
            try:
                values = _values_from_query_and_body(self)
                if parsed.path == "/download":
                    self._download(values)
                    return
                self._submit(values)
            except json.JSONDecodeError:
                _json_response(self, 400, {"ok": False, "error": "invalid_json"})
            except SubmitServerError as exc:
                _json_response(self, 400, {"ok": False, "error": str(exc)})

        def _submit(self, values: dict[str, list[str]]) -> None:
            if not _authorized(self, values, settings):
                _json_response(self, 403, {"ok": False, "error": "bad_secret"})
                return

            text = _first(values, "url") or _first(values, "text") or _first(values, "input")
            urls = extract_urls(text)
            if not urls:
                _json_response(self, 400, {"ok": False, "error": "no_supported_url"})
                return

            positions: list[int] = []
            queued_urls: list[str] = []
            duplicate_urls: list[str] = []
            for url in urls:
                now = monotonic()
                with recent_submissions_lock:
                    expired = [
                        submitted_url
                        for submitted_url, submitted_at in recent_submissions.items()
                        if now - submitted_at >= SUBMIT_DEDUP_SECONDS
                    ]
                    for submitted_url in expired:
                        recent_submissions.pop(submitted_url, None)
                    submitted_at = recent_submissions.get(url)
                    if submitted_at is not None and now - submitted_at < SUBMIT_DEDUP_SECONDS:
                        duplicate_urls.append(url)
                        continue
                    recent_submissions[url] = now

                logging.info("submit-api queued url: %s", url)
                download_format, resolution_label = _highest_download_choice(url, settings)
                positions.append(
                    job_queue.enqueue(
                        VideoJob(
                            source_chat_id=settings.submit_notify_chat_id,
                            source_message_id=None,
                            source_user_id=None,
                            url=url,
                            download_format=download_format,
                            resolution_label=resolution_label,
                        )
                    )
                )
                queued_urls.append(url)

            if duplicate_urls:
                logging.info("submit-api ignored duplicate urls: %s", duplicate_urls)

            _json_response(
                self,
                200,
                {
                    "ok": True,
                    "queued": len(queued_urls),
                    "duplicates": len(duplicate_urls),
                    "positions": positions,
                    "urls": queued_urls,
                    "duplicate_urls": duplicate_urls,
                },
            )

        def _download(self, values: dict[str, list[str]]) -> None:
            if not _authorized(self, values, settings):
                _json_response(self, 403, {"ok": False, "error": "bad_secret"})
                return

            text = _first(values, "url") or _first(values, "text") or _first(values, "input")
            urls = extract_urls(text)
            if not urls:
                _json_response(self, 400, {"ok": False, "error": "no_supported_url"})
                return

            url = urls[0]
            logging.info("download-api downloading url: %s", url)
            file_path: Path | None = None
            send_path: Path | None = None
            try:
                download_format, _resolution_label = _local_download_choice(url, settings)
                result = download_video(url, settings, download_format=download_format)
                file_path = result.file_path
                send_path = _iphone_compatible_file(file_path) if _needs_iphone_conversion(url) else file_path
                logging.info("download-api sending iPhone file: %s", send_path)
                _file_response(self, send_path, "video.mp4")
            except (BrokenPipeError, ConnectionResetError) as exc:
                logging.info("download-api client disconnected: url=%s error=%s", url, exc)
            except Exception as exc:
                logging.warning("download-api failed: url=%s error=%s", url, exc)
                _empty_response(self, 502)
            finally:
                if file_path and file_path.exists():
                    cleanup_download(file_path)
                    logging.info("download-api cleaned file: %s", file_path)
                if send_path and send_path.exists():
                    cleanup_download(send_path)
                    logging.info("download-api cleaned iPhone file: %s", send_path)

    return SubmitHandler


def start_submit_server(settings: Settings, job_queue: JobQueue) -> ThreadingHTTPServer:
    if not settings.submit_api_secret:
        raise SubmitServerError("SUBMIT_API_SECRET is empty; HTTP submit API disabled.")

    server = ThreadingHTTPServer(
        (settings.submit_api_host, settings.submit_api_port),
        make_handler(settings, job_queue),
    )
    thread = Thread(target=server.serve_forever, name="submit-api", daemon=True)
    thread.start()
    logging.info(
        "Submit API listening on %s:%s",
        settings.submit_api_host,
        settings.submit_api_port,
    )
    return server
