#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from report_export import (
    build_formal_minutes_output_path,
    convert_docx_to_pdf,
    generate_formal_minutes_docx,
    generate_formal_minutes_html,
    generate_formal_minutes_markdown,
)


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def preferred_report(session_path: Path) -> tuple[dict, bool]:
    for name, named in (("report_named.json", True), ("report_anon.json", False)):
        path = session_path / name
        if path.exists():
            return load_json(path), named
    raise RuntimeError("缺少可用于导出的 report_named.json 或 report_anon.json")


def load_classification(session_path: Path, report: dict) -> dict:
    classification = load_json(session_path / "classification.json")
    if classification:
        return classification
    return {
        "template": report.get("meeting_type", "general"),
        "confidence": 1.0,
        "reason": "从已生成纪要补充导出文件。",
    }


def load_speaker_map(session_path: Path) -> dict[str, str]:
    raw = load_json(session_path / "speaker_map.json")
    if not isinstance(raw, dict):
        return {}
    return {str(key): str(value) for key, value in raw.items() if str(value).strip()}


def export_files(session_path: Path, formats: set[str]) -> dict[str, str]:
    allowed = {"html", "docx", "md", "pdf"}
    requested = {item.lower() for item in formats if item.lower() in allowed}
    if not requested:
        raise RuntimeError("没有可生成的导出格式")

    report, named = preferred_report(session_path)
    classification = load_classification(session_path, report)
    speaker_map = load_speaker_map(session_path)

    docx_path = None
    html_path = None
    md_path = None
    pdf_path = None

    needs_docx = "docx" in requested or "pdf" in requested
    if needs_docx:
        docx_path = generate_formal_minutes_docx(
            report=report,
            classification=classification,
            session_path=session_path,
            named=named,
            speaker_map=speaker_map,
        )

    if "html" in requested:
        html_output = (
            docx_path.with_suffix(".html")
            if docx_path is not None
            else build_formal_minutes_output_path(
                session_path=session_path,
                report_title=report.get("report_title", "会议纪要"),
                version_name="实名版" if named else "匿名版",
            ).with_suffix(".html")
        )
        html_path = generate_formal_minutes_html(
            report=report,
            output_path=html_output,
            named=named,
            speaker_map=speaker_map,
        )

    if "md" in requested:
        md_output = (
            docx_path.with_suffix(".md")
            if docx_path is not None
            else build_formal_minutes_output_path(
                session_path=session_path,
                report_title=report.get("report_title", "会议纪要"),
                version_name="实名版" if named else "匿名版",
            ).with_suffix(".md")
        )
        md_path = generate_formal_minutes_markdown(
            report=report,
            output_path=md_output,
            named=named,
            speaker_map=speaker_map,
        )

    if "pdf" in requested:
        if docx_path is None:
            raise RuntimeError("生成 PDF 需要临时 DOCX，但 DOCX 未生成")
        pdf_path = convert_docx_to_pdf(docx_path)

    if "docx" not in requested and docx_path is not None:
        docx_path.unlink(missing_ok=True)
        docx_path = None

    return {
        "docx": str(docx_path) if docx_path else "",
        "html": str(html_path) if html_path else "",
        "md": str(md_path) if md_path else "",
        "pdf": str(pdf_path) if pdf_path else "",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", required=True)
    parser.add_argument("--formats", required=True)
    args = parser.parse_args()

    session_path = Path(args.session).expanduser()
    result = export_files(
        session_path=session_path,
        formats={item.strip() for item in args.formats.split(",") if item.strip()},
    )
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
