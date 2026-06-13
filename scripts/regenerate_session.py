#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from report_export import (
    convert_docx_to_pdf,
    generate_formal_minutes_docx,
    generate_formal_minutes_html,
    generate_formal_minutes_markdown,
)
from report_generation import generate_structured_report
from speaker_naming import anonymous_speaker_label


def save_speaker_map(session_path: Path, speaker_map: dict[str, str]) -> None:
    path = session_path / "speaker_map.json"
    path.write_text(
        json.dumps(speaker_map, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def render_transcript_markdown(
    segments: list[dict],
    speaker_map: dict[str, str],
    title: str,
) -> str:
    lines = [f"# {title}", ""]
    for segment in segments:
        start = format_timestamp(float(segment.get("start", 0)))
        end = format_timestamp(float(segment.get("end", 0)))
        raw_speaker = str(segment.get("speaker", "UNKNOWN"))
        speaker = speaker_map.get(raw_speaker, raw_speaker)
        text = str(segment.get("text", "")).strip()
        if not text:
            continue
        lines.append(f"- [{start} - {end}] {speaker}：{text}")
    return "\n".join(lines).strip()


def format_timestamp(seconds: float) -> str:
    total = max(0, int(round(seconds)))
    hours = total // 3600
    minutes = (total % 3600) // 60
    secs = total % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d}"


def existing_summary_files(session_path: Path, named: bool) -> set[str]:
    version_name = "实名版" if named else "匿名版"
    formats: set[str] = set()
    if any(session_path.glob(f"*{version_name}*.docx")):
        formats.add("docx")
    if any(session_path.glob(f"*{version_name}*.html")):
        formats.add("html")
    if any(session_path.glob(f"*{version_name}*.pdf")):
        formats.add("pdf")
    if any(session_path.glob(f"*{version_name}*.md")):
        formats.add("md")
    return formats


def load_transcript(
    session_path: Path,
    named: bool,
    speaker_overrides: dict[str, str] | None = None,
) -> tuple[str, dict[str, str]]:
    speaker_map_path = session_path / "speaker_map.json"
    speaker_map = (
        json.loads(speaker_map_path.read_text(encoding="utf-8"))
        if speaker_map_path.exists()
        else {}
    )
    if named:
        speaker_map = {
            raw: (
                "未知说话人"
                if raw == "UNKNOWN"
                else str(name).strip() or anonymous_speaker_label(raw)
            )
            for raw, name in speaker_map.items()
        }
    else:
        speaker_map = {
            raw: anonymous_speaker_label(raw, fallback=str(name))
            for raw, name in speaker_map.items()
        }
    if speaker_overrides:
        speaker_map = {**speaker_map, **speaker_overrides}
    save_speaker_map(session_path, speaker_map)
    segments_path = session_path / "transcript_with_speaker_raw.json"
    if segments_path.exists():
        segments = json.loads(segments_path.read_text(encoding="utf-8"))
        title = "完整转录稿（已标注说话人身份）" if named else "完整转录稿（匿名说话人版）"
        transcript = render_transcript_markdown(segments, speaker_map, title)
        output_path = session_path / ("transcript_named.md" if named else "transcript_anon.md")
        output_path.write_text(transcript, encoding="utf-8")
        return transcript, speaker_map

    preferred = session_path / ("transcript_named.md" if named else "transcript_anon.md")
    if preferred.exists():
        return preferred.read_text(encoding="utf-8"), speaker_map
    fallback = session_path / ("transcript_anon.md" if named else "transcript_named.md")
    if fallback.exists():
        return fallback.read_text(encoding="utf-8"), speaker_map
    raise RuntimeError("缺少可用于重生成的转录稿")


def regenerate(
    session_path: Path,
    template_id: str,
    speaker_overrides: dict[str, str] | None = None,
    version: str = "auto",
) -> dict:
    if version == "named":
        named = True
    elif version == "anonymous":
        named = False
    else:
        named = bool(speaker_overrides) or (session_path / "report_named.json").exists()
    transcript, speaker_map = load_transcript(
        session_path,
        named=named,
        speaker_overrides=speaker_overrides,
    )
    classification = {
        "template": template_id,
        "confidence": 1.0,
        "reason": "用户在本地会议库中手动指定模板。",
    }
    (session_path / "classification.json").write_text(
        json.dumps(classification, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    report = generate_structured_report(
        transcript_markdown=transcript,
        classification=classification,
        session_path=session_path,
        named=named,
    )

    formats = existing_summary_files(session_path, named=named)
    if not formats:
        formats = existing_summary_files(session_path, named=not named)
    if not formats:
        formats = {"html", "docx"}
    docx_path = None
    html_path = None
    md_path = None
    pdf_path = None
    if "docx" in formats or "pdf" in formats:
        docx_path = generate_formal_minutes_docx(
            report=report,
            classification=classification,
            session_path=session_path,
            named=named,
            speaker_map=speaker_map,
        )
    if "html" in formats:
        html_output = (
            docx_path.with_suffix(".html")
            if docx_path is not None
            else session_path / f"{report.get('report_title', '会议纪要')}_{'实名版' if named else '匿名版'}.html"
        )
        html_path = generate_formal_minutes_html(
            report=report,
            output_path=html_output,
            named=named,
            speaker_map=speaker_map,
        )
    if "md" in formats:
        markdown_output = (
            docx_path.with_suffix(".md")
            if docx_path is not None
            else session_path / f"{report.get('report_title', '会议纪要')}_{'实名版' if named else '匿名版'}.md"
        )
        md_path = generate_formal_minutes_markdown(
            report=report,
            output_path=markdown_output,
            named=named,
            speaker_map=speaker_map,
        )
    if "pdf" in formats:
        if docx_path is None:
            raise RuntimeError("生成 PDF 需要先生成临时 DOCX")
        pdf_path = convert_docx_to_pdf(docx_path)
    if "docx" not in formats and docx_path is not None:
        docx_path.unlink(missing_ok=True)
        docx_path = None

    if not named:
        for stale_path in [
            session_path / "report_named.json",
            session_path / "transcript_named.md",
            session_path / "summary_named.txt",
        ]:
            stale_path.unlink(missing_ok=True)
        for stale_path in session_path.glob("*实名版*"):
            if stale_path.is_file():
                stale_path.unlink(missing_ok=True)

    return {
        "template": template_id,
        "report_title": report.get("report_title", "会议纪要"),
        "version": "named" if named else "anonymous",
        "docx": str(docx_path) if docx_path else "",
        "html": str(html_path) if html_path else "",
        "md": str(md_path) if md_path else "",
        "pdf": str(pdf_path) if pdf_path else "",
    }


def load_speaker_overrides(raw_path: str) -> dict[str, str]:
    if not raw_path:
        return {}
    path = Path(raw_path).expanduser()
    if not path.exists():
        return {}
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    if not isinstance(raw, dict):
        return {}
    overrides: dict[str, str] = {}
    for key, value in raw.items():
        name = str(value).strip()
        if name:
            overrides[str(key)] = name
    return overrides


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True)
    parser.add_argument("--template", required=True)
    parser.add_argument(
        "--speaker-map-file",
        default="",
        help="JSON 文件路径，内容为 {说话人ID: 真实姓名}，用于生成实名版纪要。",
    )
    parser.add_argument(
        "--version",
        choices=["auto", "anonymous", "named"],
        default="auto",
        help="指定重生成匿名版或实名版；默认根据现有文件和说话人标注判断。",
    )
    args = parser.parse_args()
    speaker_overrides = load_speaker_overrides(args.speaker_map_file)
    result = regenerate(
        Path(args.session),
        args.template,
        speaker_overrides,
        version=args.version,
    )
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
