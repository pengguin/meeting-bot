#!/usr/bin/env python3
"""Scan and explicitly recover meeting-bot's versioned JSON documents."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from durable_storage import (
    DataStoreError,
    quarantine_corrupt_json,
    read_versioned_json_object,
    restore_json_backup,
)


KNOWN_DOCUMENT_TYPES = {
    "source_metadata.json": "session_source_metadata",
    "local_meeting_state.json": "local_meeting_state",
    "local_meeting_request.json": "local_meeting_request",
    "local_meeting_checkpoint.json": "local_meeting_checkpoint",
    "meeting_library.json": "meeting_library_metadata",
}


def resolve_owned_path(root: Path, raw_path: str) -> Path:
    root = root.expanduser().resolve()
    candidate = Path(raw_path).expanduser()
    if not candidate.is_absolute():
        candidate = root / candidate
    if candidate.is_symlink():
        raise DataStoreError(f"拒绝处理符号链接：{candidate}")
    try:
        candidate.resolve(strict=False).relative_to(root)
    except ValueError as error:
        raise DataStoreError(f"数据文件不在指定根目录内：{candidate}") from error
    return candidate


def scan_documents(root: Path) -> list[dict[str, str]]:
    root = root.expanduser().resolve()
    results: list[dict[str, str]] = []
    for filename, document_type in KNOWN_DOCUMENT_TYPES.items():
        for path in root.rglob(filename):
            relative = str(path.relative_to(root))
            try:
                payload = read_versioned_json_object(path, document_type=document_type)
                results.append(
                    {
                        "path": relative,
                        "status": "ok",
                        "schema_version": str(payload.get("schema_version", 1)),
                    }
                )
            except DataStoreError as error:
                results.append({"path": relative, "status": "error", "error": str(error)})
    return sorted(results, key=lambda item: item["path"])


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="检查或恢复会议纪要助手数据文件")
    parser.add_argument("--root", required=True, help="受管理的数据根目录")
    subparsers = parser.add_subparsers(dest="action", required=True)
    subparsers.add_parser("scan", help="只读检查已知版本化 JSON 文件")
    quarantine = subparsers.add_parser("quarantine", help="隔离确认损坏的 JSON 文件")
    quarantine.add_argument("path", help="根目录内的相对路径或绝对路径")
    restore = subparsers.add_parser("restore", help="从同目录 .bak 恢复 JSON 文件")
    restore.add_argument("path", help="根目录内的相对路径或绝对路径")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    root = Path(args.root)
    try:
        if args.action == "scan":
            results = scan_documents(root)
            print(json.dumps({"documents": results}, ensure_ascii=False, indent=2))
            return 1 if any(item["status"] == "error" for item in results) else 0
        path = resolve_owned_path(root, args.path)
        if args.action == "quarantine":
            result = quarantine_corrupt_json(path)
        else:
            result = restore_json_backup(path)
        print(json.dumps({"path": str(result), "action": args.action}, ensure_ascii=False))
        return 0
    except DataStoreError as error:
        print(f"数据恢复失败：{error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
