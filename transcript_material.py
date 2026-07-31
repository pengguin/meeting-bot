import json
import re
from pathlib import Path
from typing import Dict, List

from markdown_safety import markdown_literal
from meetingbot_config import TRANSCRIPT_MAX_CHARACTERS, TRANSCRIPT_MAX_SEGMENTS

RESERVED_METADATA_LABELS = {
    "生成时间",
    "报告版本",
    "会议类型",
    "使用说明",
    "核心判断",
    "重要性",
}


def normalize_uploaded_transcript_text(text: str, title: str = "上传的转录文字材料") -> str:
    cleaned = text.strip()
    if not cleaned:
        raise RuntimeError("转录文字材料为空")

    if len(cleaned) > TRANSCRIPT_MAX_CHARACTERS:
        raise RuntimeError(f"转录文字材料字符数超过上限（{TRANSCRIPT_MAX_CHARACTERS} 字符）")
    return f"# {markdown_literal(title)}\n\n{markdown_literal(cleaned)}"


def create_text_segments_from_transcript(text: str, session_path: Path) -> List[Dict]:
    segments: List[Dict] = []

    for idx, raw_line in enumerate(text.splitlines()):
        line = raw_line.strip()
        if not line:
            continue
        if len(segments) >= TRANSCRIPT_MAX_SEGMENTS:
            raise RuntimeError(f"转录文字材料段落数超过上限（{TRANSCRIPT_MAX_SEGMENTS} 段）")
        speaker = "TEXT"
        body = line

        speaker_match = re.match(
            r"^(?:\[\d{1,2}:\d{2}(?::\d{2})?\]\s*)?([^：:\n]{1,24})[：:]\s*(.+)$",
            line,
        )
        if speaker_match:
            candidate = speaker_match.group(1).strip()
            if is_valid_speaker_candidate(candidate):
                speaker = candidate
                body = speaker_match.group(2).strip()

        if not body:
            continue

        segments.append(
            {
                "start": float(idx),
                "end": float(idx + 1),
                "speaker": speaker or "TEXT",
                "text": body,
            }
        )

    if not segments:
        segments = [{"start": 0.0, "end": 1.0, "speaker": "TEXT", "text": text.strip()}]

    raw_path = session_path / "transcript_with_speaker_raw.json"
    raw_path.write_text(json.dumps(segments, ensure_ascii=False, indent=2), encoding="utf-8")

    transcript_segments = [
        {"start": item["start"], "end": item["end"], "text": item["text"]}
        for item in segments
    ]
    (session_path / "transcript_segments.json").write_text(
        json.dumps(transcript_segments, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    return segments


def is_valid_speaker_candidate(candidate: str) -> bool:
    normalized = candidate.strip().strip("*").lstrip("-").strip()
    if not normalized or normalized in RESERVED_METADATA_LABELS:
        return False
    if candidate.startswith(("#", "-", "*", "|", ">")):
        return False
    return True
