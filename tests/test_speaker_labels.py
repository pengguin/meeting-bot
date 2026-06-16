import json
import tempfile
import unittest
from pathlib import Path

from report_export import anonymous_speaker_label
from scripts.regenerate_session import load_transcript


class SpeakerLabelTests(unittest.TestCase):
    def test_internal_speaker_ids_have_stable_display_labels(self):
        self.assertEqual(anonymous_speaker_label("SPEAKER_00"), "说话人1")
        self.assertEqual(anonymous_speaker_label("SPEAKER_09"), "说话人10")
        self.assertEqual(anonymous_speaker_label("UNKNOWN"), "未知说话人")

    def test_named_transcript_persists_display_mapping(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory)
            (session / "speaker_map.json").write_text(
                json.dumps(
                    {"SPEAKER_00": "说话人1", "UNKNOWN": "说话人未知"},
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )
            (session / "transcript_with_speaker_raw.json").write_text(
                json.dumps(
                    [
                        {
                            "start": 0,
                            "end": 1,
                            "speaker": "SPEAKER_00",
                            "text": "你好",
                        },
                        {
                            "start": 1,
                            "end": 2,
                            "speaker": "UNKNOWN",
                            "text": "待确认",
                        },
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            transcript, speaker_map = load_transcript(
                session,
                named=True,
                speaker_overrides={"SPEAKER_00": "张老师"},
            )

            self.assertIn("张老师：你好", transcript)
            self.assertIn("未知说话人：待确认", transcript)
            self.assertEqual(speaker_map["SPEAKER_00"], "张老师")
            self.assertEqual(speaker_map["UNKNOWN"], "未知说话人")
            self.assertEqual(
                json.loads((session / "speaker_map.json").read_text(encoding="utf-8")),
                speaker_map,
            )

    def test_anonymous_transcript_hides_previous_real_names(self):
        with tempfile.TemporaryDirectory() as directory:
            session = Path(directory)
            (session / "speaker_map.json").write_text(
                json.dumps({"SPEAKER_00": "张老师"}, ensure_ascii=False),
                encoding="utf-8",
            )
            (session / "transcript_with_speaker_raw.json").write_text(
                json.dumps(
                    [
                        {
                            "start": 0,
                            "end": 1,
                            "speaker": "SPEAKER_00",
                            "text": "你好",
                        }
                    ],
                    ensure_ascii=False,
                ),
                encoding="utf-8",
            )

            transcript, speaker_map = load_transcript(session, named=False)

            self.assertIn("说话人1：你好", transcript)
            self.assertNotIn("张老师", transcript)
            self.assertEqual(speaker_map["SPEAKER_00"], "说话人1")


if __name__ == "__main__":
    unittest.main()
