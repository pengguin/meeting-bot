import tempfile
import unittest
from pathlib import Path

from report_export import generate_formal_minutes_html


class ReportExportTests(unittest.TestCase):
    def test_html_section_number_uses_full_blue_span(self) -> None:
        report = {
            "report_title": "测试会议",
            "meeting_type": "general_meeting",
            "one_sentence_takeaway": "结论",
            "executive_summary": "摘要",
            "key_metrics": {},
            "key_conclusions": [],
            "discussion_topics": [],
            "open_questions": [],
            "speaker_insights": [],
            "report_notes": [],
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "summary.html"
            generate_formal_minutes_html(report, output, named=False, speaker_map={})
            html = output.read_text(encoding="utf-8")

        self.assertIn('<span class="section-number">01</span>总览', html)
        self.assertIn(".section-number { margin-right: 8px; color: var(--blue); }", html)


if __name__ == "__main__":
    unittest.main()
