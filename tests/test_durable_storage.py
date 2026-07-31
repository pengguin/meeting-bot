import json
from pathlib import Path

import pytest

from durable_storage import (
    DataCorruptionError,
    DataStoreError,
    UnsupportedSchemaVersionError,
    atomic_write_json,
    quarantine_corrupt_json,
    read_versioned_json_object,
    restore_json_backup,
    write_versioned_json_object,
)
from scripts.data_recovery import resolve_owned_path, scan_documents


def test_versioned_write_migrates_legacy_document_and_creates_backup(tmp_path: Path):
    path = tmp_path / "metadata.json"
    path.write_text(json.dumps({"title": "旧标题"}), encoding="utf-8")

    write_versioned_json_object(
        path,
        {"title": "新标题"},
        document_type="session_source_metadata",
    )

    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["schema_version"] == 1
    assert payload["document_type"] == "session_source_metadata"
    assert payload["title"] == "新标题"
    assert json.loads((tmp_path / "metadata.json.bak").read_text(encoding="utf-8")) == {
        "title": "旧标题"
    }


def test_corrupt_existing_document_is_not_overwritten(tmp_path: Path):
    path = tmp_path / "metadata.json"
    original = b'{"title":'
    path.write_bytes(original)

    with pytest.raises(DataCorruptionError):
        write_versioned_json_object(
            path,
            {"title": "新标题"},
            document_type="session_source_metadata",
        )

    assert path.read_bytes() == original
    assert not (tmp_path / "metadata.json.bak").exists()


def test_newer_schema_is_rejected_without_mutation(tmp_path: Path):
    path = tmp_path / "metadata.json"
    atomic_write_json(
        path,
        {
            "schema_version": 99,
            "document_type": "session_source_metadata",
        },
    )

    with pytest.raises(UnsupportedSchemaVersionError):
        read_versioned_json_object(
            path,
            document_type="session_source_metadata",
        )


def test_explicit_quarantine_and_backup_restore_preserve_evidence(tmp_path: Path):
    path = tmp_path / "metadata.json"
    write_versioned_json_object(
        path,
        {"title": "第一版"},
        document_type="session_source_metadata",
        backup=False,
    )
    write_versioned_json_object(
        path,
        {"title": "第二版"},
        document_type="session_source_metadata",
    )
    path.write_text("not-json", encoding="utf-8")

    quarantine = quarantine_corrupt_json(path)
    assert quarantine.read_text(encoding="utf-8") == "not-json"
    assert not path.exists()

    restore_json_backup(path)
    restored = json.loads(path.read_text(encoding="utf-8"))
    assert restored["title"] == "第一版"


def test_valid_document_cannot_be_quarantined(tmp_path: Path):
    path = tmp_path / "metadata.json"
    atomic_write_json(path, {"valid": True})
    with pytest.raises(DataStoreError):
        quarantine_corrupt_json(path)


def test_recovery_tool_rejects_paths_outside_owned_root(tmp_path: Path):
    root = tmp_path / "owned"
    root.mkdir()
    outside = tmp_path / "outside.json"
    outside.write_text("{}", encoding="utf-8")
    with pytest.raises(DataStoreError):
        resolve_owned_path(root, str(outside))


def test_scan_reports_corruption_without_modifying_file(tmp_path: Path):
    session = tmp_path / "sessions" / "session-1"
    session.mkdir(parents=True)
    path = session / "source_metadata.json"
    original = b"broken"
    path.write_bytes(original)

    results = scan_documents(tmp_path)

    assert results[0]["status"] == "error"
    assert path.read_bytes() == original
