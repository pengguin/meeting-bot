import json
from pathlib import Path

from runtime_status import RuntimeStatusWriter


def make_writer(tmp_path: Path) -> RuntimeStatusWriter:
    runtime_dir = tmp_path / "runtime"
    return RuntimeStatusWriter(
        runtime_dir=runtime_dir,
        status_file=runtime_dir / "status.json",
        events_dir=runtime_dir / "events",
        source="test",
    )


def test_status_and_completion_event_are_written_atomically(tmp_path):
    writer = make_writer(tmp_path)
    session = tmp_path / "sessions" / "session-1"
    session.mkdir(parents=True)

    writer.write_session_status(
        task_status="processing",
        stage="transcribing",
        message="正在转写 50%",
        session_path=session,
    )
    status = json.loads(writer.status_file.read_text(encoding="utf-8"))
    assert status["session_id"] == "session-1"
    assert status["source"] == "test"
    assert status["stage"] == "transcribing"
    assert status["schema_version"] == 1
    assert status["document_type"] == "runtime_status"
    assert not list(writer.runtime_dir.glob("*.tmp"))

    docx = session / "minutes.docx"
    html = session / "minutes.html"
    writer.write_meeting_done_event(
        session_path=session,
        report={"report_title": "测试会议"},
        docx_path=docx,
        pdf_path=None,
        html_path=html,
        md_path=None,
        named=False,
    )
    events = list(writer.events_dir.glob("meeting_done_*.json"))
    assert len(events) == 1
    event = json.loads(events[0].read_text(encoding="utf-8"))
    assert event["report_title"] == "测试会议"
    assert event["version"] == "anonymous"
    assert event["document_type"] == "runtime_event"


def test_stale_processing_status_returns_to_idle(tmp_path):
    writer = make_writer(tmp_path)
    writer.write_status("processing", "diarization", "旧任务")

    writer.write_idle_if_no_active_task()

    status = json.loads(writer.status_file.read_text(encoding="utf-8"))
    assert status["task_status"] == "idle"
    assert status["stage"] == "idle"
