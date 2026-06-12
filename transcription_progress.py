import time
from pathlib import Path
from typing import Callable

import soundfile as sf


def audio_duration_seconds(audio_path: Path) -> float:
    return max(0.0, float(sf.info(str(audio_path)).duration))


def format_duration(seconds: float) -> str:
    total = max(0, int(round(seconds)))
    hours, remainder = divmod(total, 3600)
    minutes, secs = divmod(remainder, 60)
    if hours:
        return f"{hours:02d}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


class TranscriptionProgress:
    def __init__(
        self,
        duration: float,
        update: Callable[[str], None],
        min_percent_step: int = 1,
        min_interval_seconds: float = 10.0,
    ):
        self.duration = max(0.0, duration)
        self.update_callback = update
        self.min_percent_step = max(1, min_percent_step)
        self.min_interval_seconds = max(0.0, min_interval_seconds)
        self.last_percent = -1
        self.last_update_at = 0.0

    def start(self) -> None:
        self._emit(0, 0.0)

    def advance(self, processed_seconds: float) -> None:
        if self.duration <= 0:
            return

        processed = min(self.duration, max(0.0, processed_seconds))
        percent = min(99, max(0, int(processed * 100 / self.duration)))
        now = time.monotonic()
        if (
            percent < self.last_percent + self.min_percent_step
            and now < self.last_update_at + self.min_interval_seconds
        ):
            return
        self._emit(percent, processed, now=now)

    def complete(self) -> None:
        self._emit(100, self.duration)

    def _emit(
        self,
        percent: int,
        processed_seconds: float,
        now: float | None = None,
    ) -> None:
        self.last_percent = percent
        self.last_update_at = time.monotonic() if now is None else now
        message = f"正在语音转写：{percent}%"
        if self.duration > 0:
            message += (
                f"（已处理 {format_duration(processed_seconds)}"
                f" / {format_duration(self.duration)}）"
            )
        self.update_callback(message)
