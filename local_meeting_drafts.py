"""本地新增会议的「草稿」落盘工具。

这些函数只依赖标准库，独立于转写 / 说话人分离 / 纪要生成等重依赖，
便于在不安装 ML 依赖的环境下单元测试。`create_local_meeting.py` 复用它们：
- `local_meeting_state.json`：处理状态快照，供前端识别草稿、判断能否重试；
- `local_meeting_request.json`：本次新增会议的请求参数，供草稿重试时复用转录稿。
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime
from pathlib import Path
from typing import Iterable, Optional

STATE_FILENAME = "local_meeting_state.json"
REQUEST_FILENAME = "local_meeting_request.json"
CHECKPOINT_FILENAME = "local_meeting_checkpoint.json"


def runtime_timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def write_local_meeting_state(session_path: Path, payload: dict) -> Path:
    """原子写入草稿会议的状态快照到会话目录。"""
    state_path = session_path / STATE_FILENAME
    state_tmp = session_path / f".{STATE_FILENAME}.{uuid.uuid4().hex}.tmp"
    state_tmp.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    state_tmp.replace(state_path)
    return state_path


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
    request_path = session_path / REQUEST_FILENAME
    request_tmp = session_path / f".{REQUEST_FILENAME}.{uuid.uuid4().hex}.tmp"
    request_tmp.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    request_tmp.replace(request_path)
    return request_path


def read_json_object(path: Path) -> dict:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def write_local_meeting_checkpoint(
    session_path: Path,
    stage: str,
    completed_stage: Optional[str] = None,
) -> Path:
    """Persist the resumable pipeline checkpoint atomically."""
    checkpoint_path = session_path / CHECKPOINT_FILENAME
    previous = read_json_object(checkpoint_path)
    payload = {
        "stage": stage,
        "completed_stage": completed_stage or previous.get("completed_stage", ""),
        "updated_at": runtime_timestamp(),
    }
    checkpoint_tmp = session_path / f".{CHECKPOINT_FILENAME}.{uuid.uuid4().hex}.tmp"
    checkpoint_tmp.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    checkpoint_tmp.replace(checkpoint_path)
    return checkpoint_path


def load_local_meeting_checkpoint(session_path: Path) -> dict:
    return read_json_object(session_path / CHECKPOINT_FILENAME)
