"""Persistent task ledger and state machine shared by local and Feishu work."""
from __future__ import annotations

import hashlib
import json
import os
import re
import uuid
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Callable, Iterator, Optional

from durable_storage import (
    DataCorruptionError,
    DataStoreError,
    exclusive_file_lock,
    read_versioned_json_object,
    write_versioned_json_object,
)


TASK_DOCUMENT_TYPE = "unified_task"
TASK_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
TERMINAL_STATUSES = {"completed", "cancelled"}
ACTIVE_STATUSES = {"queued", "running", "cancelling"}
VALID_STATUSES = ACTIVE_STATUSES | {
    "paused",
    "cancelled",
    "failed",
    "waiting_user",
    "completed",
}
ALLOWED_TRANSITIONS = {
    "queued": {"running", "paused", "cancelled", "failed", "waiting_user"},
    "running": {"queued", "paused", "cancelling", "failed", "waiting_user", "completed"},
    "paused": {"queued", "cancelled"},
    "cancelling": {"cancelled", "failed", "paused"},
    "failed": {"queued", "cancelled"},
    "waiting_user": {"queued", "cancelled"},
    "completed": set(),
    "cancelled": {"queued"},
}


class TaskLedgerError(DataStoreError):
    pass


class InvalidTaskTransition(TaskLedgerError):
    pass


def task_timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest() if value else ""


def _validated_metadata(payload: Optional[dict[str, Any]]) -> dict[str, Any]:
    if payload is None:
        return {}
    if not isinstance(payload, dict):
        raise TaskLedgerError("任务元数据必须是 JSON 对象")
    try:
        encoded = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise TaskLedgerError(f"任务元数据无法序列化：{error}") from error
    if len(encoded) > 64 * 1024:
        raise TaskLedgerError("任务元数据超过 64 KB 上限")
    return json.loads(encoded.decode("utf-8"))


class TaskLedger:
    def __init__(self, directory: Path):
        self.directory = Path(directory)
        self.records_directory = self.directory / "records"
        self.lock_anchor = self.directory / "ledger"
        self.records_directory.mkdir(parents=True, exist_ok=True, mode=0o700)

    def _record_path(self, task_id: str) -> Path:
        if not TASK_ID_PATTERN.fullmatch(task_id):
            raise TaskLedgerError(f"任务 ID 无效：{task_id}")
        return self.records_directory / f"{task_id}.json"

    def _read_unlocked(self, task_id: str) -> dict[str, Any]:
        return read_versioned_json_object(
            self._record_path(task_id),
            document_type=TASK_DOCUMENT_TYPE,
        )

    def _write_unlocked(self, record: dict[str, Any]) -> None:
        write_versioned_json_object(
            self._record_path(str(record["task_id"])),
            record,
            document_type=TASK_DOCUMENT_TYPE,
        )

    def _record_files(self) -> list[Path]:
        return sorted(self.records_directory.glob("*.json"))

    def list_tasks(self) -> list[dict[str, Any]]:
        with exclusive_file_lock(self.lock_anchor):
            records = [
                read_versioned_json_object(path, document_type=TASK_DOCUMENT_TYPE)
                for path in self._record_files()
            ]
        return sorted(
            records,
            key=lambda item: (-int(item.get("priority", 0)), str(item.get("created_at", ""))),
        )

    def get(self, task_id: str) -> dict[str, Any]:
        with exclusive_file_lock(self.lock_anchor):
            return self._read_unlocked(task_id)

    def submit(
        self,
        *,
        source: str,
        kind: str,
        idempotency_key: str,
        principal: str = "",
        priority: int = 0,
        max_retries: int = 3,
        metadata: Optional[dict[str, Any]] = None,
        task_id: Optional[str] = None,
    ) -> tuple[dict[str, Any], bool]:
        source = source.strip().lower()
        kind = kind.strip().lower()
        if source not in {"local", "feishu"}:
            raise TaskLedgerError(f"不支持的任务来源：{source}")
        if not kind:
            raise TaskLedgerError("任务类型不能为空")
        idempotency_sha256 = _digest(idempotency_key.strip())
        if not idempotency_sha256:
            raise TaskLedgerError("任务幂等键不能为空")
        requested_task_id = task_id or uuid.uuid4().hex
        self._record_path(requested_task_id)
        now = task_timestamp()

        with exclusive_file_lock(self.lock_anchor):
            for path in self._record_files():
                existing = read_versioned_json_object(path, document_type=TASK_DOCUMENT_TYPE)
                if existing.get("idempotency_sha256") == idempotency_sha256:
                    return existing, False
            record: dict[str, Any] = {
                "task_id": requested_task_id,
                "source": source,
                "kind": kind,
                "principal_sha256": _digest(principal.strip()),
                "idempotency_sha256": idempotency_sha256,
                "priority": int(priority),
                "status": "queued",
                "stage": "queued",
                "checkpoint": "",
                "retry_count": 0,
                "max_retries": max(0, int(max_retries)),
                "error": {},
                "artifacts": {},
                "metadata": _validated_metadata(metadata),
                "worker": {},
                "created_at": now,
                "updated_at": now,
                "history": [
                    {"status": "queued", "stage": "queued", "at": now, "message": "任务已提交"}
                ],
            }
            self._write_unlocked(record)
            return record, True

    def _update(
        self,
        task_id: str,
        mutation: Callable[[dict[str, Any]], None],
        *,
        history_message: str = "",
    ) -> dict[str, Any]:
        with exclusive_file_lock(self.lock_anchor):
            record = self._read_unlocked(task_id)
            return self._update_unlocked(record, mutation, history_message=history_message)

    def _update_unlocked(
        self,
        record: dict[str, Any],
        mutation: Callable[[dict[str, Any]], None],
        *,
        history_message: str = "",
    ) -> dict[str, Any]:
        previous_status = str(record.get("status", ""))
        previous_stage = str(record.get("stage", ""))
        mutation(record)
        status = str(record.get("status", ""))
        if status not in VALID_STATUSES:
            raise TaskLedgerError(f"任务状态无效：{status}")
        now = task_timestamp()
        record["updated_at"] = now
        if status != previous_status or str(record.get("stage", "")) != previous_stage or history_message:
            history = list(record.get("history", []))[-49:]
            history.append(
                {
                    "status": status,
                    "stage": str(record.get("stage", "")),
                    "at": now,
                    "message": history_message,
                }
            )
            record["history"] = history
        self._write_unlocked(record)
        return record

    @staticmethod
    def _transition_record(record: dict[str, Any], target: str) -> None:
        current = str(record.get("status", ""))
        if target == current:
            return
        if target not in ALLOWED_TRANSITIONS.get(current, set()):
            raise InvalidTaskTransition(f"任务不能从 {current} 转换到 {target}")
        record["status"] = target

    def start(
        self,
        task_id: str,
        *,
        worker_id: str,
        pid: Optional[int] = None,
        lease_seconds: int = 120,
    ) -> dict[str, Any]:
        def mutation(record: dict[str, Any]) -> None:
            if record.get("status") != "queued":
                raise InvalidTaskTransition("只有排队中的任务可以开始执行")
            self._transition_record(record, "running")
            record["stage"] = "starting"
            record["worker"] = {
                "worker_id": worker_id,
                "pid": int(pid or os.getpid()),
                "lease_expires_at": (
                    datetime.now().astimezone() + timedelta(seconds=max(30, lease_seconds))
                ).isoformat(timespec="seconds"),
            }
            record["error"] = {}

        return self._update(task_id, mutation, history_message="任务开始执行")

    def heartbeat(self, task_id: str, lease_seconds: int = 120) -> dict[str, Any]:
        def mutation(record: dict[str, Any]) -> None:
            if record.get("status") != "running":
                raise InvalidTaskTransition("只有运行中的任务可以续租")
            worker = dict(record.get("worker", {}))
            worker["lease_expires_at"] = (
                datetime.now().astimezone() + timedelta(seconds=max(30, lease_seconds))
            ).isoformat(timespec="seconds")
            record["worker"] = worker

        return self._update(task_id, mutation)

    def update_stage(
        self,
        task_id: str,
        stage: str,
        *,
        checkpoint: Optional[str] = None,
        artifacts: Optional[dict[str, str]] = None,
        message: str = "",
    ) -> dict[str, Any]:
        normalized_stage = stage.strip()
        if not normalized_stage:
            raise TaskLedgerError("任务阶段不能为空")

        def mutation(record: dict[str, Any]) -> None:
            if record.get("status") != "running":
                raise InvalidTaskTransition("只有运行中的任务可以更新阶段")
            record["stage"] = normalized_stage
            if checkpoint is not None:
                record["checkpoint"] = checkpoint.strip()
            if artifacts:
                merged = dict(record.get("artifacts", {}))
                merged.update({str(key): str(value) for key, value in artifacts.items()})
                record["artifacts"] = merged
            worker = dict(record.get("worker", {}))
            worker["lease_expires_at"] = (
                datetime.now().astimezone() + timedelta(seconds=120)
            ).isoformat(timespec="seconds")
            record["worker"] = worker

        return self._update(task_id, mutation, history_message=message)

    def pause(self, task_id: str, message: str = "任务已暂停") -> dict[str, Any]:
        def mutation(record: dict[str, Any]) -> None:
            self._transition_record(record, "paused")
            record["stage"] = "paused"
            record["worker"] = {}

        return self._update(task_id, mutation, history_message=message)

    def cancel(self, task_id: str, message: str = "任务已取消") -> dict[str, Any]:
        def mutation(record: dict[str, Any]) -> None:
            self._transition_record(record, "cancelled")
            record["stage"] = "cancelled"
            record["worker"] = {}

        return self._update(task_id, mutation, history_message=message)

    def fail(
        self,
        task_id: str,
        *,
        code: str,
        message: str,
        retryable: bool,
    ) -> dict[str, Any]:
        def mutation(record: dict[str, Any]) -> None:
            self._transition_record(record, "failed")
            record["stage"] = "failed"
            record["worker"] = {}
            record["error"] = {
                "code": code.strip() or "unknown",
                "message": message[:2000],
                "retryable": bool(retryable),
            }

        return self._update(task_id, mutation, history_message=message[:500])

    def wait_for_user(self, task_id: str, message: str) -> dict[str, Any]:
        def mutation(record: dict[str, Any]) -> None:
            self._transition_record(record, "waiting_user")
            record["stage"] = "waiting_user"
            record["worker"] = {}
            record["error"] = {
                "code": "interrupted",
                "message": message[:2000],
                "retryable": True,
            }

        return self._update(task_id, mutation, history_message=message[:500])

    def complete(
        self,
        task_id: str,
        *,
        artifacts: Optional[dict[str, str]] = None,
    ) -> dict[str, Any]:
        def mutation(record: dict[str, Any]) -> None:
            self._transition_record(record, "completed")
            record["stage"] = "completed"
            record["checkpoint"] = "completed"
            record["worker"] = {}
            record["error"] = {}
            if artifacts:
                merged = dict(record.get("artifacts", {}))
                merged.update({str(key): str(value) for key, value in artifacts.items()})
                record["artifacts"] = merged

        return self._update(task_id, mutation, history_message="任务已完成")

    def retry(self, task_id: str) -> dict[str, Any]:
        def mutation(record: dict[str, Any]) -> None:
            if record.get("status") not in {"paused", "failed", "waiting_user", "cancelled"}:
                raise InvalidTaskTransition("当前任务状态不可重试")
            retries = int(record.get("retry_count", 0))
            maximum = int(record.get("max_retries", 0))
            if retries >= maximum:
                raise InvalidTaskTransition("任务重试次数已达上限")
            self._transition_record(record, "queued")
            record["stage"] = "queued"
            record["retry_count"] = retries + 1
            record["worker"] = {}
            record["error"] = {}

        return self._update(task_id, mutation, history_message="任务已重新排队")

    @staticmethod
    def _worker_is_alive(record: dict[str, Any]) -> bool:
        worker = record.get("worker", {})
        pid = worker.get("pid") if isinstance(worker, dict) else None
        if not isinstance(pid, int) or pid <= 0:
            return False
        try:
            os.kill(pid, 0)
        except OSError:
            return False
        raw_lease = str(worker.get("lease_expires_at", ""))
        try:
            lease = datetime.fromisoformat(raw_lease)
        except ValueError:
            return False
        return lease >= datetime.now().astimezone()

    def audit_unfinished(self) -> list[dict[str, Any]]:
        recovered: list[dict[str, Any]] = []
        with exclusive_file_lock(self.lock_anchor):
            for path in self._record_files():
                record = read_versioned_json_object(path, document_type=TASK_DOCUMENT_TYPE)
                status = str(record.get("status", ""))
                if status not in ACTIVE_STATUSES:
                    continue
                if status in {"running", "cancelling"} and self._worker_is_alive(record):
                    continue
                if record.get("source") == "local":
                    message = "检测到执行进程已退出，可从检查点继续"

                    def mutation(item: dict[str, Any]) -> None:
                        self._transition_record(item, "paused")
                        item["stage"] = "paused"
                        item["worker"] = {}
                else:
                    message = "后台服务重启后无法安全重放原飞书事件，请重新发送或重试"

                    def mutation(item: dict[str, Any]) -> None:
                        self._transition_record(item, "waiting_user")
                        item["stage"] = "waiting_user"
                        item["worker"] = {}
                        item["error"] = {
                            "code": "interrupted",
                            "message": message,
                            "retryable": True,
                        }
                recovered.append(
                    self._update_unlocked(record, mutation, history_message=message)
                )
        return recovered


_ACTIVE_TASK: ContextVar[tuple[TaskLedger, str] | None] = ContextVar(
    "meeting_bot_active_task",
    default=None,
)


@contextmanager
def bind_task(ledger: TaskLedger, task_id: str) -> Iterator[None]:
    token = _ACTIVE_TASK.set((ledger, task_id))
    try:
        yield
    finally:
        _ACTIVE_TASK.reset(token)


def active_task_id() -> str:
    active = _ACTIVE_TASK.get()
    return active[1] if active is not None else ""


def update_active_task(
    stage: str,
    *,
    checkpoint: Optional[str] = None,
    artifacts: Optional[dict[str, str]] = None,
    message: str = "",
) -> None:
    active = _ACTIVE_TASK.get()
    if active is None:
        return
    ledger, task_id = active
    current = ledger.get(task_id)
    current_artifacts = current.get("artifacts", {})
    artifacts_changed = bool(
        artifacts
        and any(str(current_artifacts.get(key, "")) != str(value) for key, value in artifacts.items())
    )
    if (
        current.get("stage") == stage
        and checkpoint is None
        and not artifacts_changed
    ):
        return
    ledger.update_stage(
        task_id,
        stage,
        checkpoint=checkpoint,
        artifacts=artifacts,
        message=message,
    )
