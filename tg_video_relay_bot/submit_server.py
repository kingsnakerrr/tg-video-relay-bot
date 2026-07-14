from __future__ import annotations

from email import policy
from email.parser import BytesParser
import json
import logging
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from typing import Any
from urllib.parse import parse_qs, urlparse

from .config import Settings
from .downloader import DownloadError, probe_resolutions
from .jobs import JobQueue, VideoJob
from .links import extract_urls


MAX_BODY_BYTES = 64 * 1024


class SubmitServerError(RuntimeError):
    pass


def _is_youtube_url(url: str) -> bool:
    lowered = url.lower()
    return "youtube.com" in lowered or "youtu.be" in lowered


def _highest_download_choice(url: str, settings: Settings) -> tuple[str | None, str | None]:
    if not _is_youtube_url(url):
        return None, None
    try:
        probe = probe_resolutions(url, settings)
    except DownloadError as exc:
        logging.warning("submit-api YouTube format probe failed: url=%s error=%s", url, exc)
        return None, None
    if not probe.choices:
        logging.warning("submit-api YouTube format probe returned no choices: url=%s", url)
        return None, None
    choice = probe.choices[0]
    logging.info(
        "submit-api selected highest YouTube format: url=%s label=%s selector=%s",
        url,
        choice.label,
        choice.format_selector,
    )
    return choice.format_selector, choice.label


def _json_response(handler: BaseHTTPRequestHandler, status: int, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Content-Length", str(len(body)))
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.wfile.write(body)


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


def _authorized(handler: BaseHTTPRequestHandler, values: dict[str, list[str]], settings: Settings) -> bool:
    if not settings.submit_api_secret:
        return False
    submitted = (
        handler.headers.get("X-Submit-Secret")
        or _first(values, "secret")
        or _first(values, "token")
    )
    return submitted == settings.submit_api_secret


def make_handler(settings: Settings, job_queue: JobQueue) -> type[BaseHTTPRequestHandler]:
    class SubmitHandler(BaseHTTPRequestHandler):
        server_version = "TelegramVideoRelaySubmit/1.0"

        def log_message(self, fmt: str, *args: Any) -> None:
            logging.info("submit-api %s - %s", self.address_string(), fmt % args)

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                _json_response(self, 200, {"ok": True})
                return
            if parsed.path != "/submit":
                _json_response(self, 404, {"ok": False, "error": "not_found"})
                return

            values = parse_qs(parsed.query, keep_blank_values=True)
            self._submit(_normalize_values(values))

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path != "/submit":
                _json_response(self, 404, {"ok": False, "error": "not_found"})
                return
            try:
                values = parse_qs(parsed.query, keep_blank_values=True)
                body_values = _parse_body(self)
                values.update(body_values)
                self._submit(_normalize_values(values))
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
            for url in urls:
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

            _json_response(
                self,
                200,
                {
                    "ok": True,
                    "queued": len(urls),
                    "positions": positions,
                    "urls": urls,
                },
            )

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
