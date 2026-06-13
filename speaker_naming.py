import re
from typing import Dict, Iterable

# 匿名标签统一按声纹 ID 的数字编号（SPEAKER_00 → 说话人1），
# 与菜单栏 App 内 MeetingLibraryStore.anonymousSpeakerLabel 保持同一规则；
# 不按出现顺序编号，避免重新生成纪要后"说话人N"变号。

_SPEAKER_ID_PATTERN = re.compile(r"SPEAKER[_\s-]?(\d+)", re.IGNORECASE)


def anonymous_speaker_label(raw: str, fallback: str = "") -> str:
    if raw == "UNKNOWN":
        return "未知说话人"
    if raw == "TEXT":
        return "转录文本"

    match = _SPEAKER_ID_PATTERN.fullmatch(raw)
    if match:
        return f"说话人{int(match.group(1)) + 1}"

    return fallback or raw


def build_anonymous_speaker_map(speaker_ids: Iterable[str]) -> Dict[str, str]:
    speaker_map: Dict[str, str] = {}
    for raw in speaker_ids:
        if raw not in speaker_map:
            speaker_map[raw] = anonymous_speaker_label(raw)
    return speaker_map
