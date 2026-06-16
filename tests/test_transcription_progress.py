import unittest
from unittest.mock import patch

from transcription_progress import TranscriptionProgress, format_duration


class TranscriptionProgressTests(unittest.TestCase):
    def test_formats_short_and_long_durations(self):
        self.assertEqual(format_duration(65), "01:05")
        self.assertEqual(format_duration(3661), "01:01:01")

    def test_reports_processed_audio_percentage(self):
        messages = []
        progress = TranscriptionProgress(100, messages.append)

        with patch("transcription_progress.time.monotonic", side_effect=[0, 1, 2, 3]):
            progress.start()
            progress.advance(42)
            progress.complete()

        self.assertEqual(messages[0], "正在语音转写：0%（已处理 00:00 / 01:40）")
        self.assertEqual(messages[1], "正在语音转写：42%（已处理 00:42 / 01:40）")
        self.assertEqual(messages[2], "正在语音转写：100%（已处理 01:40 / 01:40）")

    def test_caps_running_progress_at_99_percent(self):
        messages = []
        progress = TranscriptionProgress(100, messages.append)
        progress.advance(100)
        self.assertIn("99%", messages[-1])


if __name__ == "__main__":
    unittest.main()
