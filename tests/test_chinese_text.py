import unittest

from chinese_text import simplify_chinese


class ChineseTextTests(unittest.TestCase):
    def test_simplify_chinese_converts_whisper_style_traditional_text(self) -> None:
        self.assertEqual(
            simplify_chinese("我會離開研究所，並建立新的研究中心。"),
            "我会离开研究所，并建立新的研究中心。",
        )

    def test_simplify_chinese_preserves_existing_simplified_text(self) -> None:
        self.assertEqual(
            simplify_chinese("这是已经转换好的简体中文，那么继续处理。"),
            "这是已经转换好的简体中文，那么继续处理。",
        )


if __name__ == "__main__":
    unittest.main()
