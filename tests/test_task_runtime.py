import json
import tempfile
import threading
import time
from pathlib import Path

from task_runtime import BoundedTaskExecutor, PersistentMessageDeduplicator


def test_message_deduplicator_persists_and_bounds_entries():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "processed.json"
        dedupe = PersistentMessageDeduplicator(path, max_entries=2)
        assert dedupe.claim("one")
        assert not dedupe.claim("one")
        assert dedupe.claim("two")
        assert dedupe.claim("three")
        assert list(json.loads(path.read_text(encoding="utf-8"))) == ["two", "three"]
        assert not PersistentMessageDeduplicator(path, max_entries=2).claim("three")


def test_bounded_executor_rejects_when_worker_and_queue_are_full():
    executor = BoundedTaskExecutor(max_workers=1, max_pending=1)
    release = threading.Event()
    started = threading.Event()

    def blocking_task():
        started.set()
        release.wait(timeout=2)

    assert executor.submit(blocking_task)
    assert started.wait(timeout=1)
    assert executor.submit(lambda: time.sleep(0.01))
    assert not executor.submit(lambda: None)
    release.set()
