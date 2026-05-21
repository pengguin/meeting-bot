import json
import tempfile
import unittest
from pathlib import Path

import session_store
from session_store import find_reusable_session, transcript_text_sha256


class SessionStoreTests(unittest.TestCase):
    def test_set_latest_session_updates_latest_session_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            latest_session_file = Path(tmpdir) / "latest_session.txt"
            session = Path(tmpdir) / "20260515_120000_abcd12"
            session.mkdir()

            original_latest_session_file = session_store.LATEST_SESSION_FILE
            try:
                session_store.LATEST_SESSION_FILE = latest_session_file
                session_store.set_latest_session(session)
                self.assertEqual(session_store.get_latest_session(), session)
            finally:
                session_store.LATEST_SESSION_FILE = original_latest_session_file

    def test_find_reusable_session_prefers_metadata_match(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            session = root / "20260515_120000_abcd12"
            session.mkdir()
            (session / "transcript_anon.md").write_text("# transcript", encoding="utf-8")
            (session / "source_metadata.json").write_text(
                json.dumps(
                    {
                        "source_kind": "transcript_text",
                        "source_sha256": "matched",
                    }
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                find_reusable_session("matched", "transcript_text", session_dir=root),
                session,
            )

    def test_find_reusable_session_supports_legacy_text_sessions(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            session = root / "20260515_120000_abcd12"
            session.mkdir()
            content = "张三：项目继续推进"
            (session / "transcript_anon.md").write_text(content, encoding="utf-8")

            self.assertEqual(
                find_reusable_session(
                    transcript_text_sha256(content),
                    "transcript_text",
                    session_dir=root,
                ),
                session,
            )


if __name__ == "__main__":
    unittest.main()
