import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from speaker_naming import anonymous_speaker_label, build_anonymous_speaker_map


def test_speaker_ids_numbered_by_id_digits():
    assert anonymous_speaker_label("SPEAKER_00") == "说话人1"
    assert anonymous_speaker_label("SPEAKER_01") == "说话人2"
    assert anonymous_speaker_label("SPEAKER_07") == "说话人8"


def test_speaker_id_separator_variants():
    assert anonymous_speaker_label("SPEAKER 03") == "说话人4"
    assert anonymous_speaker_label("SPEAKER-03") == "说话人4"
    assert anonymous_speaker_label("speaker_03") == "说话人4"


def test_special_labels():
    assert anonymous_speaker_label("UNKNOWN") == "未知说话人"
    assert anonymous_speaker_label("TEXT") == "转录文本"


def test_unrecognized_label_uses_fallback_then_raw():
    assert anonymous_speaker_label("访谈嘉宾", fallback="嘉宾") == "嘉宾"
    assert anonymous_speaker_label("访谈嘉宾") == "访谈嘉宾"


def test_build_map_dedupes_and_keeps_stable_numbering():
    speaker_map = build_anonymous_speaker_map(
        ["SPEAKER_01", "SPEAKER_00", "SPEAKER_01", "UNKNOWN"]
    )
    # 编号跟随 ID 数字，与出现顺序无关。
    assert speaker_map == {
        "SPEAKER_01": "说话人2",
        "SPEAKER_00": "说话人1",
        "UNKNOWN": "未知说话人",
    }
