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
from .telegram_api import TelegramApi


@dataclass(frozen=True)
class VideoJob:
    source_chat_id: int | str | None
    source_message_id: int | None
    source_user_id: int | None
    url: str


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
        self._reply(job, "收到链接，开始下载。")

        file_path: Path | None = None
        try:
            file_path, title = download_video(job.url, self.settings)
            size_mb = file_path.stat().st_size / 1024 / 1024
            self._reply(job, f"下载完成：{title}\n大小：{size_mb:.1f} MB\n开始上传到 {len(self.settings.target_chat_ids)} 个目标。")

            upload_path, note = prepare_upload_file(file_path, self.settings)
            if note:
                self._reply(job, note)

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
                    "部分目标上传失败，本地文件已保留，方便你手动处理：\n"
                    f"{file_path}\n\n"
                    + "\n".join(failures[:8]),
                )
                if not self.settings.delete_after_all_uploads:
                    cleanup_download(file_path)
                return

            cleanup_download(file_path)
            self._reply(job, "全部目标上传成功，本地视频已删除。")
        except Exception as exc:
            self._reply(job, f"任务失败：{exc}")
            if file_path and file_path.exists() and not self.settings.delete_after_all_uploads:
                cleanup_download(file_path)

    def _upload_one(self, target_chat_id: int | str, file_path: Path, caption: str) -> None:
        if self.settings.upload_mode == "document":
            self.api.send_document(target_chat_id, file_path, caption=caption)
            return
        self.api.send_video(target_chat_id, file_path, caption=caption)
