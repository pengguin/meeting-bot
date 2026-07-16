import json
import tempfile
import unittest
from pathlib import Path

import local_meeting_drafts
from local_meeting_drafts import (
    CHECKPOINT_FILENAME,
    REQUEST_FILENAME,
    STATE_FILENAME,
    write_local_meeting_request,
    write_local_meeting_checkpoint,
    write_local_meeting_state,
)


class WriteLocalMeetingRequestTests(unittest.TestCase):
    def test_persists_normalized_fields(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_path = Path(tmp)
            path = write_local_meeting_request(
                session_path,
                title="  季度评审会  ",
                template="auto",
                formats={"docx", "html", "pdf"},
            )

            self.assertEqual(path, session_path / REQUEST_FILENAME)
            data = json.loads(path.read_text(encoding="utf-8"))
            # 标题去除首尾空白。
            self.assertEqual(data["title"], "季度评审会")
            self.assertEqual(data["template"], "auto")
            # formats 落盘为稳定排序，便于比对与复现。
            self.assertEqual(data["formats"], ["docx", "html", "pdf"])
            self.assertTrue(data["updated_at"])

    def test_overwrites_previous_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_path = Path(tmp)
            write_local_meeting_request(session_path, "旧标题", "general_meeting", {"html"})
            write_local_meeting_request(session_path, "新标题", "research_seminar", {"md"})

            data = json.loads((session_path / REQUEST_FILENAME).read_text(encoding="utf-8"))
            self.assertEqual(data["title"], "新标题")
            self.assertEqual(data["template"], "research_seminar")
            self.assertEqual(data["formats"], ["md"])
            self.assertEqual(list(session_path.glob(f".{REQUEST_FILENAME}.*.tmp")), [])


def test_checkpoint_preserves_last_completed_stage():
    with tempfile.TemporaryDirectory() as tmp:
        session_path = Path(tmp)
        write_local_meeting_checkpoint(session_path, "transcribing", "diarization")
        write_local_meeting_checkpoint(session_path, "paused")
        data = json.loads((session_path / CHECKPOINT_FILENAME).read_text(encoding="utf-8"))
        assert data["stage"] == "paused"
        assert data["completed_stage"] == "diarization"


class WriteLocalMeetingStateTests(unittest.TestCase):
    def _payload(self, task_status="processing", stage="generating_report"):
        return {
            "service_status": "running",
            "task_status": task_status,
            "stage": stage,
            "message": "正在生成会议纪要",
            "session_id": "sess-123",
            "session_dir": "/tmp/sess-123",
            "updated_at": local_meeting_drafts.runtime_timestamp(),
            "source": "local_meeting",
        }

    def test_persists_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_path = Path(tmp)
            path = write_local_meeting_state(session_path, self._payload())

            self.assertEqual(path, session_path / STATE_FILENAME)
            data = json.loads(path.read_text(encoding="utf-8"))
            # 这些字段是前端 LocalMeetingStateSnapshot 解码所依赖的契约。
            self.assertEqual(data["task_status"], "processing")
            self.assertEqual(data["stage"], "generating_report")
            self.assertEqual(data["message"], "正在生成会议纪要")
            self.assertEqual(data["source"], "local_meeting")

    def test_overwrite_replaces_status_and_leaves_no_temp(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_path = Path(tmp)
            write_local_meeting_state(session_path, self._payload(task_status="processing"))
            write_local_meeting_state(
                session_path,
                self._payload(task_status="error", stage="error"),
            )

            data = json.loads((session_path / STATE_FILENAME).read_text(encoding="utf-8"))
            self.assertEqual(data["task_status"], "error")
            self.assertEqual(data["stage"], "error")
            # 原子写入：临时文件不应残留。
            leftovers = list(session_path.glob(f".{STATE_FILENAME}.*.tmp"))
            self.assertEqual(leftovers, [])

    def test_state_and_request_are_separate_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            session_path = Path(tmp)
            write_local_meeting_state(session_path, self._payload())
            write_local_meeting_request(session_path, "标题", "auto", {"html"})

            names = sorted(p.name for p in session_path.iterdir())
            self.assertEqual(names, [REQUEST_FILENAME, STATE_FILENAME])


if __name__ == "__main__":
    unittest.main()
