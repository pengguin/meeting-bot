"""Durable local persistence primitives shared by meeting-bot processes.

The application stores user-owned metadata in ordinary files so it remains
inspectable and recoverable without a database tool. This module centralizes
the safety properties those files require: bounded reads, symlink rejection,
cross-process locking, atomic replacement, backups, and explicit corruption
handling.
"""
from __future__ import annotations

import copy
import fcntl
import json
import os
import shutil
import stat
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Iterator


CURRENT_SCHEMA_VERSION = 1
DEFAULT_MAX_JSON_BYTES = 16 * 1024 * 1024
_MISSING = object()


class DataStoreError(RuntimeError):
    """Base error for durable local storage failures."""


class DataCorruptionError(DataStoreError):
    """Raised when an existing document cannot be trusted or decoded."""


class UnsupportedSchemaVersionError(DataStoreError):
    """Raised when a document was written by a newer incompatible version."""


def _timestamp() -> str:
    return datetime.now().astimezone().strftime("%Y%m%dT%H%M%S%z")


def _lock_path(path: Path) -> Path:
    return path.with_name(f".{path.name}.lock")


def _ensure_private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        path.chmod(0o700)
    except OSError:
        pass


def _reject_symlink(path: Path) -> None:
    if path.is_symlink():
        raise DataCorruptionError(f"拒绝访问符号链接数据文件：{path}")


@contextmanager
def exclusive_file_lock(path: Path) -> Iterator[None]:
    """Serialize readers that mutate and writers across local processes."""

    path = Path(path)
    _ensure_private_directory(path.parent)
    lock_path = _lock_path(path)
    _reject_symlink(lock_path)
    with lock_path.open("a+b") as handle:
        try:
            os.fchmod(handle.fileno(), 0o600)
        except OSError:
            pass
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _read_regular_file(path: Path, max_bytes: int) -> bytes:
    _reject_symlink(path)
    try:
        file_stat = path.stat()
    except OSError as error:
        raise DataStoreError(f"无法读取数据文件 {path}：{error}") from error
    if not stat.S_ISREG(file_stat.st_mode):
        raise DataCorruptionError(f"数据路径不是普通文件：{path}")
    if file_stat.st_size > max_bytes:
        raise DataCorruptionError(f"数据文件超过大小上限：{path}")
    try:
        with path.open("rb") as handle:
            data = handle.read(max_bytes + 1)
    except OSError as error:
        raise DataStoreError(f"无法读取数据文件 {path}：{error}") from error
    if len(data) > max_bytes:
        raise DataCorruptionError(f"数据文件超过大小上限：{path}")
    return data


def _decode_json_object(path: Path, data: bytes) -> dict[str, Any]:
    try:
        payload = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DataCorruptionError(f"JSON 数据损坏：{path}：{error}") from error
    if not isinstance(payload, dict):
        raise DataCorruptionError(f"JSON 数据必须是对象：{path}")
    return payload


def read_json_object(
    path: Path,
    *,
    missing: Any = _MISSING,
    max_bytes: int = DEFAULT_MAX_JSON_BYTES,
) -> dict[str, Any]:
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        if missing is _MISSING:
            raise DataStoreError(f"数据文件不存在：{path}")
        return copy.deepcopy(missing)
    return _decode_json_object(path, _read_regular_file(path, max_bytes))


def normalize_versioned_document(
    payload: dict[str, Any],
    *,
    document_type: str,
    current_schema_version: int = CURRENT_SCHEMA_VERSION,
) -> dict[str, Any]:
    normalized = dict(payload)
    raw_version = normalized.get("schema_version", 0)
    if isinstance(raw_version, bool) or not isinstance(raw_version, int) or raw_version < 0:
        raise DataCorruptionError(f"{document_type} 的 schema_version 无效")
    if raw_version > current_schema_version:
        raise UnsupportedSchemaVersionError(
            f"{document_type} 数据版本 {raw_version} 高于当前支持版本 {current_schema_version}"
        )
    stored_type = normalized.get("document_type")
    if stored_type not in (None, "", document_type):
        raise DataCorruptionError(
            f"数据类型不匹配：期望 {document_type}，实际为 {stored_type}"
        )
    normalized["schema_version"] = current_schema_version
    normalized["document_type"] = document_type
    return normalized


def read_versioned_json_object(
    path: Path,
    *,
    document_type: str,
    missing: Any = _MISSING,
    max_bytes: int = DEFAULT_MAX_JSON_BYTES,
    current_schema_version: int = CURRENT_SCHEMA_VERSION,
) -> dict[str, Any]:
    payload = read_json_object(path, missing=missing, max_bytes=max_bytes)
    if missing is not _MISSING and payload == missing and not Path(path).exists():
        return payload
    return normalize_versioned_document(
        payload,
        document_type=document_type,
        current_schema_version=current_schema_version,
    )


def _fsync_directory(path: Path) -> None:
    try:
        directory_fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(directory_fd)
    except OSError:
        pass
    finally:
        os.close(directory_fd)


def _write_bytes_unlocked(path: Path, data: bytes, mode: int) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        try:
            path.chmod(mode)
        except OSError:
            pass
        _fsync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_write_bytes(
    path: Path,
    data: bytes,
    *,
    mode: int = 0o600,
    backup: bool = False,
    protect_existing_json: bool = False,
    max_existing_bytes: int = DEFAULT_MAX_JSON_BYTES,
) -> Path:
    path = Path(path)
    _ensure_private_directory(path.parent)
    _reject_symlink(path)
    with exclusive_file_lock(path):
        existing: bytes | None = None
        if path.exists():
            existing = _read_regular_file(path, max_existing_bytes)
            if protect_existing_json:
                _decode_json_object(path, existing)
        if backup and existing is not None:
            backup_path = path.with_name(f"{path.name}.bak")
            _reject_symlink(backup_path)
            _write_bytes_unlocked(backup_path, existing, mode)
        _write_bytes_unlocked(path, data, mode)
    return path


def atomic_write_text(
    path: Path,
    text: str,
    *,
    mode: int = 0o600,
    backup: bool = False,
) -> Path:
    return atomic_write_bytes(path, text.encode("utf-8"), mode=mode, backup=backup)


def atomic_write_json(
    path: Path,
    payload: Any,
    *,
    backup: bool = False,
    protect_existing: bool = False,
    mode: int = 0o600,
) -> Path:
    encoded = (json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode(
        "utf-8"
    )
    return atomic_write_bytes(
        path,
        encoded,
        mode=mode,
        backup=backup,
        protect_existing_json=protect_existing,
    )


def write_versioned_json_object(
    path: Path,
    payload: dict[str, Any],
    *,
    document_type: str,
    backup: bool = True,
    protect_existing: bool = True,
    current_schema_version: int = CURRENT_SCHEMA_VERSION,
) -> Path:
    normalized = normalize_versioned_document(
        payload,
        document_type=document_type,
        current_schema_version=current_schema_version,
    )
    return atomic_write_json(
        path,
        normalized,
        backup=backup,
        protect_existing=protect_existing,
    )


def quarantine_corrupt_json(path: Path) -> Path:
    """Move an invalid JSON object aside after an explicit recovery action."""

    path = Path(path)
    with exclusive_file_lock(path):
        data = _read_regular_file(path, DEFAULT_MAX_JSON_BYTES)
        try:
            _decode_json_object(path, data)
        except DataCorruptionError:
            pass
        else:
            raise DataStoreError(f"数据文件有效，不应隔离：{path}")
        quarantine = path.with_name(f"{path.name}.corrupt-{_timestamp()}-{uuid.uuid4().hex[:8]}")
        os.replace(path, quarantine)
        _fsync_directory(path.parent)
        return quarantine


def restore_json_backup(path: Path) -> Path:
    """Restore a valid `.bak` while preserving the current file for inspection."""

    path = Path(path)
    backup_path = path.with_name(f"{path.name}.bak")
    backup_data = _read_regular_file(backup_path, DEFAULT_MAX_JSON_BYTES)
    _decode_json_object(backup_path, backup_data)
    with exclusive_file_lock(path):
        if path.exists() or path.is_symlink():
            current_data = _read_regular_file(path, DEFAULT_MAX_JSON_BYTES)
            preserved = path.with_name(f"{path.name}.replaced-{_timestamp()}-{uuid.uuid4().hex[:8]}")
            _write_bytes_unlocked(preserved, current_data, 0o600)
        _write_bytes_unlocked(path, backup_data, 0o600)
    return path
