import json
import tempfile
import unittest
from pathlib import Path

from transcript_material import (
    create_text_segments_from_transcript,
    normalize_uploaded_transcript_text,
)


class TranscriptMaterialTests(unittest.TestCase):
    def test_normalize_uploaded_text_adds_heading(self) -> None:
        normalized = normalize_uploaded_transcript_text("张三：开始")
        self.assertTrue(normalized.startswith("# 上传的转录文字材料"))

    def test_create_text_segments_extracts_speakers(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            session = Path(tmpdir)
            segments = create_text_segments_from_transcript(
                "[00:01] 张三：开始\n李四: 继续",
                session,
            )

            self.assertEqual([item["speaker"] for item in segments], ["张三", "李四"])

            raw_segments = json.loads(
                (session / "transcript_with_speaker_raw.json").read_text(encoding="utf-8")
            )
            self.assertEqual(len(raw_segments), 2)

    def test_create_text_segments_ignores_report_metadata_as_speakers(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            session = Path(tmpdir)
            segments = create_text_segments_from_transcript(
                "\n".join(
                    [
                        "- 生成时间：2026-05-18 10:00",
                        "- 会议类型：访谈 / 座谈整理",
                        "**核心判断：** 这不是说话人",
                        "重要性：这也不是说话人",
                        "张老师：这是正常说话人",
                    ]
                ),
                session,
            )

            self.assertEqual(
                [item["speaker"] for item in segments],
                ["TEXT", "TEXT", "TEXT", "TEXT", "张老师"],
            )


if __name__ == "__main__":
    unittest.main()
