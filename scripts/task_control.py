#!/usr/bin/env python3
"""Inspect and control persistent meeting tasks without editing ledger files."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from task_ledger import TaskLedger, TaskLedgerError


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="会议纪要助手统一任务账本工具")
    parser.add_argument("--runtime-dir", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    commands.add_parser("audit")
    for name in ("get", "retry", "cancel"):
        command = commands.add_parser(name)
        command.add_argument("task_id")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    ledger = TaskLedger(Path(args.runtime_dir) / "tasks")
    try:
        if args.command == "list":
            payload = ledger.list_tasks()
        elif args.command == "audit":
            payload = ledger.audit_unfinished()
        elif args.command == "get":
            payload = ledger.get(args.task_id)
        elif args.command == "retry":
            payload = ledger.retry(args.task_id)
        else:
            payload = ledger.cancel(args.task_id)
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0
    except TaskLedgerError as error:
        print(f"任务操作失败：{error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
