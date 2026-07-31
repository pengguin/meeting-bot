"""本地新增会议的「草稿」落盘工具。

这些函数只依赖标准库，独立于转写 / 说话人分离 / 纪要生成等重依赖，
便于在不安装 ML 依赖的环境下单元测试。`create_local_meeting.py` 复用它们：
- `local_meeting_state.json`：处理状态快照，供前端识别草稿、判断能否重试；
- `local_meeting_request.json`：本次新增会议的请求参数，供草稿重试时复用转录稿。
"""
from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Iterable, Optional

from durable_storage import read_versioned_json_object, write_versioned_json_object

STATE_FILENAME = "local_meeting_state.json"
REQUEST_FILENAME = "local_meeting_request.json"
CHECKPOINT_FILENAME = "local_meeting_checkpoint.json"


def runtime_timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def write_local_meeting_state(session_path: Path, payload: dict) -> Path:
    """原子写入草稿会议的状态快照到会话目录。"""
    state_path = session_path / STATE_FILENAME
    state_payload = dict(payload)
    # runtime/status.json and the per-session draft use different durable
    # document types even though they share the same visible status fields.
    state_payload.pop("schema_version", None)
    state_payload.pop("document_type", None)
    return write_versioned_json_object(
        state_path,
        state_payload,
        document_type="local_meeting_state",
    )


def write_local_meeting_request(
    session_path: Path,
    title: str,
    template: str,
    formats: Iterable[str],
) -> Path:
    """落盘本次新增会议的请求参数，供草稿会议重试时复用。"""
    payload = {
        "title": title.strip(),
        "template": template,
        "formats": sorted(formats),
        "updated_at": runtime_timestamp(),
    }
    return write_versioned_json_object(
        session_path / REQUEST_FILENAME,
        payload,
        document_type="local_meeting_request",
    )


def read_json_object(path: Path, document_type: str) -> dict:
    return read_versioned_json_object(
        path,
        document_type=document_type,
        missing={},
    )


def write_local_meeting_checkpoint(
    session_path: Path,
    stage: str,
    completed_stage: Optional[str] = None,
) -> Path:
    """Persist the resumable pipeline checkpoint atomically."""
    checkpoint_path = session_path / CHECKPOINT_FILENAME
    previous = read_json_object(checkpoint_path, "local_meeting_checkpoint")
    payload = {
        "stage": stage,
        "completed_stage": completed_stage or previous.get("completed_stage", ""),
        "updated_at": runtime_timestamp(),
    }
    return write_versioned_json_object(
        checkpoint_path,
        payload,
        document_type="local_meeting_checkpoint",
    )


def load_local_meeting_checkpoint(session_path: Path) -> dict:
    return read_json_object(
        session_path / CHECKPOINT_FILENAME,
        "local_meeting_checkpoint",
    )
