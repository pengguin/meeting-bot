import multiprocessing
import os
from pathlib import Path

import pytest

from task_ledger import InvalidTaskTransition, TaskLedger


def _submit_same_task(directory: str, output) -> None:
    ledger = TaskLedger(Path(directory))
    record, created = ledger.submit(
        source="feishu",
        kind="audio",
        idempotency_key="same-message",
        principal="chat-a",
    )
    output.put((record["task_id"], created))


def test_task_state_machine_persists_stage_checkpoint_and_retry(tmp_path: Path):
    ledger = TaskLedger(tmp_path / "tasks")
    task, created = ledger.submit(
        source="local",
        kind="audio",
        idempotency_key="local-1",
        principal="app",
        metadata={"session_id": "session-1"},
    )
    assert created
    ledger.start(task["task_id"], worker_id="test", pid=os.getpid())
    ledger.update_stage(
        task["task_id"],
        "transcribing",
        checkpoint="diarization",
        artifacts={"session_dir": "/tmp/session-1"},
    )
    ledger.pause(task["task_id"])
    retried = ledger.retry(task["task_id"])

    assert retried["status"] == "queued"
    assert retried["retry_count"] == 1
    assert retried["checkpoint"] == "diarization"
    assert retried["artifacts"]["session_dir"] == "/tmp/session-1"


def test_invalid_transition_does_not_modify_completed_task(tmp_path: Path):
    ledger = TaskLedger(tmp_path / "tasks")
    task, _ = ledger.submit(source="local", kind="text", idempotency_key="done")
    ledger.start(task["task_id"], worker_id="test")
    ledger.complete(task["task_id"])

    with pytest.raises(InvalidTaskTransition):
        ledger.pause(task["task_id"])
    assert ledger.get(task["task_id"])["status"] == "completed"


def test_task_cannot_be_started_by_two_workers(tmp_path: Path):
    ledger = TaskLedger(tmp_path / "tasks")
    task, _ = ledger.submit(source="local", kind="audio", idempotency_key="single-worker")
    ledger.start(task["task_id"], worker_id="worker-one", pid=os.getpid())

    with pytest.raises(InvalidTaskTransition):
        ledger.start(task["task_id"], worker_id="worker-two", pid=os.getpid())

    current = ledger.get(task["task_id"])
    assert current["worker"]["worker_id"] == "worker-one"


def test_idempotency_is_atomic_across_processes(tmp_path: Path):
    context = multiprocessing.get_context("spawn")
    output = context.Queue()
    processes = [
        context.Process(target=_submit_same_task, args=(str(tmp_path / "tasks"), output))
        for _ in range(3)
    ]
    for process in processes:
        process.start()
    for process in processes:
        process.join(timeout=10)
        assert process.exitcode == 0

    results = [output.get(timeout=2) for _ in processes]
    assert len({task_id for task_id, _created in results}) == 1
    assert sum(1 for _task_id, created in results if created) == 1


def test_restart_audit_pauses_local_and_requires_user_for_feishu(tmp_path: Path):
    ledger = TaskLedger(tmp_path / "tasks")
    local, _ = ledger.submit(source="local", kind="audio", idempotency_key="local")
    feishu, _ = ledger.submit(source="feishu", kind="audio", idempotency_key="feishu")
    ledger.start(local["task_id"], worker_id="dead", pid=999999, lease_seconds=30)
    ledger.start(feishu["task_id"], worker_id="dead", pid=999999, lease_seconds=30)

    recovered = ledger.audit_unfinished()

    statuses = {item["source"]: item["status"] for item in recovered}
    assert statuses == {"local": "paused", "feishu": "waiting_user"}


def test_task_record_does_not_store_raw_principal_or_idempotency_key(tmp_path: Path):
    ledger = TaskLedger(tmp_path / "tasks")
    task, _ = ledger.submit(
        source="feishu",
        kind="text",
        idempotency_key="message-secret",
        principal="chat-secret",
    )
    raw = (ledger.records_directory / f"{task['task_id']}.json").read_text(encoding="utf-8")
    assert "message-secret" not in raw
    assert "chat-secret" not in raw
