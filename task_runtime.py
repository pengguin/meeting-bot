"""Bounded background execution and persistent Feishu message deduplication."""
from __future__ import annotations

import json
import threading
import time
import uuid
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Callable


class PersistentMessageDeduplicator:
    def __init__(self, path: Path, max_entries: int = 2000, ttl_seconds: int = 86400):
        self.path = path
        self.max_entries = max(1, max_entries)
        self.ttl_seconds = max(60, ttl_seconds)
        self._lock = threading.Lock()
        self._entries: OrderedDict[str, float] = OrderedDict()
        self._load()

    def _load(self) -> None:
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        now = time.time()
        for message_id, timestamp in raw.items() if isinstance(raw, dict) else []:
            if isinstance(timestamp, (int, float)) and now - timestamp <= self.ttl_seconds:
                self._entries[str(message_id)] = float(timestamp)
        self._trim()

    def _trim(self) -> None:
        cutoff = time.time() - self.ttl_seconds
        for message_id in list(self._entries):
            if self._entries[message_id] >= cutoff:
                break
            self._entries.pop(message_id, None)
        while len(self._entries) > self.max_entries:
            self._entries.popitem(last=False)

    def claim(self, message_id: str) -> bool:
        with self._lock:
            self._trim()
            if message_id in self._entries:
                return False
            self._entries[message_id] = time.time()
            self._trim()
            self._persist()
            return True

    def release(self, message_id: str) -> None:
        with self._lock:
            if self._entries.pop(message_id, None) is not None:
                self._persist()

    def _persist(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.parent / f".{self.path.name}.{uuid.uuid4().hex}.tmp"
        tmp.write_text(json.dumps(self._entries, ensure_ascii=False), encoding="utf-8")
        tmp.replace(self.path)


class BoundedTaskExecutor:
    def __init__(
        self,
        max_workers: int = 1,
        max_pending: int = 8,
        max_pending_per_principal: int = 2,
    ):
        self._executor = ThreadPoolExecutor(
            max_workers=max(1, max_workers),
            thread_name_prefix="meeting-task",
        )
        self._slots = threading.BoundedSemaphore(max(1, max_workers + max_pending))
        self._max_pending_per_principal = max(1, max_pending_per_principal)
        self._principal_lock = threading.Lock()
        self._principal_counts: dict[str, int] = {}

    def submit(self, function: Callable, *args, principal: str = "global", **kwargs) -> bool:
        if not self._slots.acquire(blocking=False):
            return False
        principal = principal.strip() or "global"
        with self._principal_lock:
            current = self._principal_counts.get(principal, 0)
            if current >= self._max_pending_per_principal:
                self._slots.release()
                return False
            self._principal_counts[principal] = current + 1

        def run() -> None:
            try:
                function(*args, **kwargs)
            finally:
                self._release_principal(principal)
                self._slots.release()

        try:
            self._executor.submit(run)
        except Exception:
            self._release_principal(principal)
            self._slots.release()
            raise
        return True

    def _release_principal(self, principal: str) -> None:
        with self._principal_lock:
            remaining = self._principal_counts.get(principal, 1) - 1
            if remaining > 0:
                self._principal_counts[principal] = remaining
            else:
                self._principal_counts.pop(principal, None)
