from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path
from queue import Queue
from threading import Thread
from typing import Any

from .config import Settings
from .compressor import prepare_upload_file
from .downloader import cleanup_download, download_video
from .links import trim_caption
from .media_info import probe_video_info
from .telegram_api import TelegramApi


@dataclass(frozen=True)
class VideoJob:
    source_chat_id: int | str | None
    source_message_id: int | None
    source_user_id: int | None
    url: str
    download_format: str | None = None
    resolution_label: str | None = None


class JobQueue:
    def __init__(self, api: TelegramApi, settings: Settings) -> None:
        self.api = api
        self.settings = settings
        self.queue: Queue[VideoJob] = Queue()

    def start(self) -> None:
        for index in range(self.settings.worker_count):
            worker = Thread(target=self._worker, name=f"video-worker-{index + 1}", daemon=True)
            worker.start()

    def enqueue(self, job: VideoJob) -> int:
        self.queue.put(job)
        return self.queue.qsize()

    def pending_count(self) -> int:
        return self.queue.qsize()

    def _worker(self) -> None:
        while True:
            job = self.queue.get()
            try:
                self._process(job)
            finally:
                self.queue.task_done()

    def _reply(self, job: VideoJob, text: str) -> None:
        if job.source_chat_id is None:
            logging.info("%s", text)
            return
        self.api.send_message(
            job.source_chat_id,
            text,
            reply_to_message_id=job.source_message_id,
        )

    def _process(self, job: VideoJob) -> None:
        if job.resolution_label:
            self._reply(job, f"收到链接，开始下载：{job.resolution_label}")
        else:
            self._reply(job, "收到链接，开始下载。")

        file_path: Path | None = None
        try:
            result = download_video(job.url, self.settings, download_format=job.download_format)
            file_path = result.file_path
            title = result.title
            size_mb = file_path.stat().st_size / 1024 / 1024
            downloaded_info = probe_video_info(file_path)
            downloaded_label = downloaded_info.label if downloaded_info else "未知"
            self._reply(
                job,
                f"下载完成：{title}\n"
                f"下载文件：{downloaded_label}，{size_mb:.1f} MB\n"
                f"yt-dlp 实际格式：{result.format_summary}\n"
                f"开始上传到 {len(self.settings.target_chat_ids)} 个目标。",
            )

            upload_path, note = prepare_upload_file(file_path, self.settings)
            upload_info = probe_video_info(upload_path)
            upload_size_mb = upload_path.stat().st_size / 1024 / 1024
            if note:
                upload_label = upload_info.label if upload_info else "未知"
                self._reply(job, f"{note}\n上传文件：{upload_label}，{upload_size_mb:.1f} MB")
            elif upload_path == file_path:
                self._reply(job, "未压缩，按下载原文件上传。")

            failures: list[str] = []
            caption = trim_caption(f"{title}\n{job.url}")
            for target_chat_id in self.settings.target_chat_ids:
                try:
                    self._upload_one(target_chat_id, upload_path, caption)
                except Exception as exc:
                    failures.append(f"{target_chat_id}: {exc}")

            if failures:
                self._reply(
                    job,
                    "部分目标上传失败，本地文件将自动删除，避免占用 VPS 空间：\n\n"
                    + "\n".join(failures[:8]),
                )
                return

            self._reply(job, "全部目标上传成功，本地视频将自动删除。")
        except Exception as exc:
            self._reply(job, f"任务失败：{exc}")
        finally:
            if file_path and file_path.exists():
                cleanup_download(file_path)
                self._reply(job, "本次任务本地文件已清理。")

    def _upload_one(self, target_chat_id: int | str, file_path: Path, caption: str) -> None:
        if self.settings.upload_mode == "document":
            self.api.send_document(target_chat_id, file_path, caption=caption)
            return
        self.api.send_video(target_chat_id, file_path, caption=caption)
