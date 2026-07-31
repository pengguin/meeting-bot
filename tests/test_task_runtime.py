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


def test_message_deduplicator_release_allows_retry():
    with tempfile.TemporaryDirectory() as tmp:
        dedupe = PersistentMessageDeduplicator(Path(tmp) / "processed.json")
        assert dedupe.claim("retry")
        dedupe.release("retry")
        assert dedupe.claim("retry")


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


def test_bounded_executor_preserves_capacity_for_another_principal():
    executor = BoundedTaskExecutor(
        max_workers=1,
        max_pending=4,
        max_pending_per_principal=2,
    )
    release = threading.Event()
    started = threading.Event()

    def blocking_task():
        started.set()
        release.wait(timeout=2)

    assert executor.submit(blocking_task, principal="chat-a")
    assert started.wait(timeout=1)
    assert executor.submit(lambda: release.wait(timeout=2), principal="chat-a")
    assert not executor.submit(lambda: None, principal="chat-a")
    assert executor.submit(lambda: None, principal="chat-b")
    release.set()
