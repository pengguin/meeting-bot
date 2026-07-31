import json
import tempfile
import unittest
from pathlib import Path

import session_store
from session_store import find_reusable_session, read_text_file, transcript_text_sha256


class SessionStoreTests(unittest.TestCase):
    def test_read_text_file_rejects_size_before_materializing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "large.txt"
            path.write_bytes(b"x" * 11)

            with self.assertRaisesRegex(RuntimeError, "超过允许大小"):
                read_text_file(path, max_bytes=10, max_characters=100)

    def test_read_text_file_rejects_character_limit(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "large.txt"
            path.write_text("abcdefghijk", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "字符数超过上限"):
                read_text_file(path, max_bytes=100, max_characters=10)
    def test_set_latest_session_updates_latest_session_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            latest_session_file = Path(tmpdir) / "latest_session.txt"
            session = Path(tmpdir) / "20260515_120000_abcd12"
            session.mkdir()

            original_latest_session_file = session_store.LATEST_SESSION_FILE
            original_session_dir = session_store.SESSION_DIR
            try:
                session_store.LATEST_SESSION_FILE = latest_session_file
                session_store.SESSION_DIR = Path(tmpdir)
                session_store.set_latest_session(session)
                self.assertEqual(session_store.get_latest_session(), session.resolve())
            finally:
                session_store.LATEST_SESSION_FILE = original_latest_session_file
                session_store.SESSION_DIR = original_session_dir

    def test_latest_session_is_isolated_by_scope_without_global_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            session_a = root / "20260515_120000_aaaaaa"
            session_b = root / "20260515_120000_bbbbbb"
            session_a.mkdir()
            session_b.mkdir()

            originals = (
                session_store.LATEST_SESSION_FILE,
                session_store.LATEST_SESSIONS_DIR,
                session_store.SESSION_DIR,
            )
            try:
                session_store.LATEST_SESSION_FILE = root / "latest_session.txt"
                session_store.LATEST_SESSIONS_DIR = root / "runtime" / "latest_sessions"
                session_store.SESSION_DIR = root
                session_store.set_latest_session(session_a)
                session_store.set_latest_session(session_a, "feishu:chat:a")
                session_store.set_latest_session(session_b, "feishu:chat:b")

                self.assertEqual(
                    session_store.get_latest_session("feishu:chat:a"),
                    session_a.resolve(),
                )
                self.assertEqual(
                    session_store.get_latest_session("feishu:chat:b"),
                    session_b.resolve(),
                )
                self.assertIsNone(session_store.get_latest_session("feishu:chat:c"))
                index_names = [path.name for path in session_store.LATEST_SESSIONS_DIR.iterdir()]
                self.assertFalse(any("chat" in name for name in index_names))
            finally:
                (
                    session_store.LATEST_SESSION_FILE,
                    session_store.LATEST_SESSIONS_DIR,
                    session_store.SESSION_DIR,
                ) = originals

    def test_latest_session_rejects_path_outside_session_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            sessions = root / "sessions"
            sessions.mkdir()
            outside = root / "private"
            outside.mkdir()
            latest = root / "latest_session.txt"
            latest.write_text(str(outside), encoding="utf-8")

            originals = (session_store.LATEST_SESSION_FILE, session_store.SESSION_DIR)
            try:
                session_store.LATEST_SESSION_FILE = latest
                session_store.SESSION_DIR = sessions
                self.assertIsNone(session_store.get_latest_session())
            finally:
                session_store.LATEST_SESSION_FILE, session_store.SESSION_DIR = originals

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

    def test_find_reusable_session_requires_matching_scope(self) -> None:
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
                        "session_scope_sha256": session_store.session_scope_digest(
                            "feishu:chat:a"
                        ),
                    }
                ),
                encoding="utf-8",
            )

            self.assertEqual(
                find_reusable_session(
                    "matched",
                    "transcript_text",
                    session_dir=root,
                    session_scope="feishu:chat:a",
                ),
                session,
            )
            self.assertIsNone(
                find_reusable_session(
                    "matched",
                    "transcript_text",
                    session_dir=root,
                    session_scope="feishu:chat:b",
                )
            )


if __name__ == "__main__":
    unittest.main()
