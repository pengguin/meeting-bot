import os
import re
import json
import uuid
from pathlib import Path
from typing import Dict, List, Tuple, Optional

# Allow unsupported Apple GPU operations to fall back to CPU.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

# pyannote telemetry can block long-running background processes when its
# exporter connection becomes stale. The bot runs fully locally, so disable it.
os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "false")
os.environ.setdefault("OTEL_SDK_DISABLED", "true")

import lark_oapi as lark
from lark_oapi.api.im.v1 import P2ImMessageReceiveV1

from audio_pipeline import AudioPipeline
from feishu_io import FeishuIO, ReferencedMessageAuthorizationError
from llm_backend import llm_runtime_description, run_llm, write_json_atomic
from durable_storage import atomic_write_text
from markdown_safety import markdown_literal
from runtime_status import RuntimeStatusWriter, runtime_timestamp
from speaker_naming import build_anonymous_speaker_map
from meetingbot_config import (
    ASR_MODEL,
    AUDIO_MAX_DECODED_MB,
    AUDIO_MAX_DURATION_SECONDS,
    AUDIO_STAGE_TIMEOUT_SECONDS,
    DIARIZATION_MODEL,
    DOWNLOAD_DIR,
    FEISHU_APP_ID,
    FEISHU_APP_SECRET,
    FFMPEG_BIN,
    HF_TOKEN,
    DOWNLOAD_MAX_MB,
    DOWNLOAD_RETENTION_HOURS,
    DOWNLOAD_TOTAL_MAX_MB,
    RUNTIME_DIR,
    RUNTIME_EVENTS_DIR,
    RUNTIME_STATUS_FILE,
    SCHEMA_DIR,
    TASK_MAX_PENDING,
    TASK_MAX_PENDING_PER_PRINCIPAL,
    TASK_MAX_WORKERS,
    get_allowed_templates,
    get_template_descriptions,
    get_template_guidance,
    get_template_names,
)
from report_export import (
    convert_docx_to_pdf,
    generate_formal_minutes_docx,
    generate_formal_minutes_html,
    generate_formal_minutes_markdown,
)
from session_store import (
    create_session,
    create_text_session,
    file_sha256,
    find_reusable_session,
    get_latest_session,
    is_audio_material_file,
    is_text_material_file,
    read_text_file,
    session_scope_digest,
    set_latest_session,
    transcript_text_sha256,
    write_session_metadata,
)
from transcript_material import (
    create_text_segments_from_transcript,
    normalize_uploaded_transcript_text,
)
from task_runtime import BoundedTaskExecutor, PersistentMessageDeduplicator


# ============================================================
# 2. 全局状态
# ============================================================

MESSAGE_DEDUPLICATOR = PersistentMessageDeduplicator(
    RUNTIME_DIR / "processed_message_ids.json"
)
MESSAGE_TASKS = BoundedTaskExecutor(
    max_workers=TASK_MAX_WORKERS,
    max_pending=TASK_MAX_PENDING,
    max_pending_per_principal=TASK_MAX_PENDING_PER_PRINCIPAL,
)
RUNTIME_STATUS = RuntimeStatusWriter(
    runtime_dir=RUNTIME_DIR,
    status_file=RUNTIME_STATUS_FILE,
    events_dir=RUNTIME_EVENTS_DIR,
    source="feishu_bot",
)
write_runtime_status = RUNTIME_STATUS.write_status
write_session_runtime_status = RUNTIME_STATUS.write_session_status
write_meeting_done_event = RUNTIME_STATUS.write_meeting_done_event
RUNTIME_STATUS.write_idle_if_no_active_task()


# ============================================================
# 4. 初始化飞书客户端
# ============================================================

feishu_client = (
    lark.Client.builder()
    .app_id(FEISHU_APP_ID)
    .app_secret(FEISHU_APP_SECRET)
    .log_level(lark.LogLevel.INFO)
    .build()
)
FEISHU_IO = FeishuIO(
    app_id=FEISHU_APP_ID,
    app_secret=FEISHU_APP_SECRET,
    download_dir=DOWNLOAD_DIR,
    download_max_mb=DOWNLOAD_MAX_MB,
    download_total_max_mb=DOWNLOAD_TOTAL_MAX_MB,
    retention_hours=DOWNLOAD_RETENTION_HOURS,
    client=feishu_client,
)
AUDIO_PIPELINE = AudioPipeline(
    asr_model_name=ASR_MODEL,
    diarization_model_name=DIARIZATION_MODEL,
    hf_token=HF_TOKEN,
    ffmpeg_bin=FFMPEG_BIN,
    status_callback=write_session_runtime_status,
    max_duration_seconds=AUDIO_MAX_DURATION_SECONDS,
    max_decoded_mb=AUDIO_MAX_DECODED_MB,
    stage_timeout_seconds=AUDIO_STAGE_TIMEOUT_SECONDS,
)

reply_text = FEISHU_IO.reply_text
reply_long_text = FEISHU_IO.reply_long_text
download_message_resource = FEISHU_IO.download_message_resource
get_referenced_message_payload = FEISHU_IO.get_referenced_message_payload
reply_file = FEISHU_IO.reply_file
convert_audio_to_wav_16k_mono = AUDIO_PIPELINE.convert_audio_to_wav_16k_mono
diarize_audio = AUDIO_PIPELINE.diarize_audio
transcribe_audio = AUDIO_PIPELINE.transcribe_audio


def is_force_retranscribe(text: str = "") -> bool:
    normalized = text.strip().lower()
    return any(
        keyword in normalized
        for keyword in [
            "重新转录",
            "重新识别",
            "重新asr",
            "重新 asr",
            "强制转录",
            "force transcribe",
            "retranscribe",
        ]
    )


def is_regenerate_report_request(text: str = "") -> bool:
    normalized = text.strip().lower()
    return any(
        keyword in normalized
        for keyword in [
            "重新生成",
            "重生成",
            "重新整理",
            "生成会议纪要",
            "生成纪要",
            "生成报告",
            "重新汇编",
            "汇编纪要",
            "regenerate",
        ]
    )


def looks_like_transcript_text(text: str) -> bool:
    cleaned = text.strip()
    if len(cleaned) >= 500:
        return True

    lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
    if len(lines) >= 8 and len(cleaned) >= 180:
        return True

    speaker_like = sum(
        1
        for line in lines
        if re.match(r"^(\[?\d{1,2}:\d{2}(?::\d{2})?\]?|说话人\d+|speaker\s*\d+|SPEAKER[_\s-]?\d+|[\u4e00-\u9fa5]{2,6}[：:])", line, re.I)
    )
    return speaker_like >= 3


# ============================================================
# 11. 时间戳融合：为每段转写分配说话人
# ============================================================

def overlap_duration(
    a_start: float,
    a_end: float,
    b_start: float,
    b_end: float,
) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def assign_speakers_to_transcript(
    transcript_segments: List[Dict],
    diarization_segments: List[Dict],
    session_path: Path,
) -> List[Dict]:
    merged: List[Dict] = []

    for t in transcript_segments:
        best_speaker = "UNKNOWN"
        best_overlap = 0.0

        for d in diarization_segments:
            ov = overlap_duration(
                t["start"],
                t["end"],
                d["start"],
                d["end"],
            )
            if ov > best_overlap:
                best_overlap = ov
                best_speaker = d["speaker"]

        merged.append(
            {
                "start": t["start"],
                "end": t["end"],
                "speaker": best_speaker,
                "text": t["text"],
            }
        )

    out_path = session_path / "transcript_with_speaker_raw.json"
    write_json_atomic(out_path, merged)

    return merged


# ============================================================
# 12. 说话人匿名映射与转录稿渲染
# ============================================================

def build_default_speaker_map(
    merged_segments: List[Dict],
    session_path: Path,
) -> Dict[str, str]:
    speaker_map = build_anonymous_speaker_map(
        seg["speaker"] for seg in merged_segments
    )

    save_speaker_map(session_path, speaker_map)
    return speaker_map


def load_speaker_map(session_path: Path) -> Dict[str, str]:
    path = session_path / "speaker_map.json"
    if not path.exists():
        raise RuntimeError("speaker_map.json 不存在")
    return json.loads(path.read_text(encoding="utf-8"))


def save_speaker_map(session_path: Path, speaker_map: Dict[str, str]) -> None:
    write_json_atomic(session_path / "speaker_map.json", speaker_map)


def format_timestamp(seconds: float) -> str:
    seconds = max(0, int(seconds))
    h = seconds // 3600
    m = (seconds % 3600) // 60
    s = seconds % 60

    if h > 0:
        return f"{h:02d}:{m:02d}:{s:02d}"
    return f"{m:02d}:{s:02d}"


def merge_adjacent_same_speaker(
    merged_segments: List[Dict],
    gap_threshold: float = 1.2,
) -> List[Dict]:
    if not merged_segments:
        return []

    results = [merged_segments[0].copy()]

    for seg in merged_segments[1:]:
        prev = results[-1]
        same_speaker = prev["speaker"] == seg["speaker"]
        close_enough = seg["start"] - prev["end"] <= gap_threshold

        if same_speaker and close_enough:
            prev["end"] = seg["end"]
            prev["text"] = prev["text"].rstrip() + " " + seg["text"].lstrip()
        else:
            results.append(seg.copy())

    return results


def render_transcript_markdown(
    merged_segments: List[Dict],
    speaker_map: Dict[str, str],
    title: str,
) -> str:
    readable_segments = merge_adjacent_same_speaker(merged_segments)
    lines = [f"# {markdown_literal(title)}", ""]

    for seg in readable_segments:
        speaker_label = speaker_map.get(seg["speaker"], seg["speaker"])
        ts = format_timestamp(seg["start"])
        lines.append(f"\\[{ts}\\] {markdown_literal(speaker_label)}：")
        lines.append(markdown_literal(seg["text"]))
        lines.append("")

    return "\n".join(lines).strip()


def save_transcript_versions(
    session_path: Path,
    merged_segments: List[Dict],
    speaker_map: Dict[str, str],
    named: bool,
) -> str:
    if named:
        title = "完整转录稿（已标注说话人身份）"
        filename = "transcript_named.md"
    else:
        title = "完整转录稿（匿名说话人版）"
        filename = "transcript_anon.md"

    markdown = render_transcript_markdown(
        merged_segments=merged_segments,
        speaker_map=speaker_map,
        title=title,
    )

    path = session_path / filename
    atomic_write_text(path, markdown)
    return markdown


def load_merged_segments(session_path: Path) -> List[Dict]:
    path = session_path / "transcript_with_speaker_raw.json"
    if not path.exists():
        raise RuntimeError("缺少 transcript_with_speaker_raw.json")
    return json.loads(path.read_text(encoding="utf-8"))


# ============================================================
# 13. Codex JSON Schema
# ============================================================

def ensure_classification_schema() -> Path:
    schema_path = SCHEMA_DIR / "meeting_classification.schema.json"
    allowed_templates = sorted(get_allowed_templates())

    schema = {
        "type": "object",
        "properties": {
            "template": {
                "type": "string",
                "enum": allowed_templates,
            },
            "confidence": {
                "type": "number",
                "minimum": 0,
                "maximum": 1,
            },
            "reason": {"type": "string"},
        },
        "required": ["template", "confidence", "reason"],
        "additionalProperties": False,
    }

    write_json_atomic(schema_path, schema)

    return schema_path


def ensure_report_schema() -> Path:
    schema_path = SCHEMA_DIR / "meeting_report.schema.json"
    allowed_templates = sorted(get_allowed_templates())

    schema = {
        "type": "object",
        "properties": {
            "report_title": {"type": "string"},
            "meeting_type": {
                "type": "string",
                "enum": allowed_templates,
            },
            "version": {
                "type": "string",
                "enum": ["anonymous", "named"],
            },
            "one_sentence_takeaway": {"type": "string"},
            "executive_summary": {"type": "string"},
            "key_metrics": {
                "type": "object",
                "properties": {
                    "conclusion_count": {"type": "integer", "minimum": 0},
                    "action_item_count": {"type": "integer", "minimum": 0},
                    "open_question_count": {"type": "integer", "minimum": 0},
                },
                "required": [
                    "conclusion_count",
                    "action_item_count",
                    "open_question_count",
                ],
                "additionalProperties": False,
            },
            "key_conclusions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string"},
                        "detail": {"type": "string"},
                    },
                    "required": ["title", "detail"],
                    "additionalProperties": False,
                },
            },
            "action_items": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "priority": {
                            "type": "string",
                            "enum": ["高", "中", "低", "待确认"],
                        },
                        "task": {"type": "string"},
                        "owner": {"type": "string"},
                        "deadline": {"type": "string"},
                        "notes": {"type": "string"},
                    },
                    "required": [
                        "priority",
                        "task",
                        "owner",
                        "deadline",
                        "notes",
                    ],
                    "additionalProperties": False,
                },
            },
            "discussion_topics": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string"},
                        "summary": {"type": "string"},
                        "points": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
                    },
                    "required": ["title", "summary", "points"],
                    "additionalProperties": False,
                },
            },
            "open_questions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "question": {"type": "string"},
                        "why_it_matters": {"type": "string"},
                    },
                    "required": ["question", "why_it_matters"],
                    "additionalProperties": False,
                },
            },
            "speaker_insights": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {
                        "speaker": {"type": "string"},
                        "role": {"type": "string"},
                        "main_views": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
                    },
                    "required": ["speaker", "role", "main_views"],
                    "additionalProperties": False,
                },
            },
            "report_notes": {
                "type": "array",
                "items": {"type": "string"},
            },
        },
        "required": [
            "report_title",
            "meeting_type",
            "version",
            "one_sentence_takeaway",
            "executive_summary",
            "key_metrics",
            "key_conclusions",
            "action_items",
            "discussion_topics",
            "open_questions",
            "speaker_insights",
            "report_notes",
        ],
        "additionalProperties": False,
    }

    write_json_atomic(schema_path, schema)

    return schema_path


# ============================================================
# 14. LLM 判断会议类型（后端由 llm_backend 按 .env 配置选择）
# ============================================================

def classify_meeting_type(
    transcript_markdown: str,
    session_path: Path,
) -> Dict:
    schema_path = ensure_classification_schema()
    output_path = session_path / "classification.json"
    template_names = get_template_names()
    template_descriptions = get_template_descriptions()
    allowed_templates = get_allowed_templates()
    template_options = "\n".join(
        f"{index}. {template_id}：{template_names[template_id]}。{template_descriptions.get(template_id, '')}"
        for index, template_id in enumerate(sorted(allowed_templates), start=1)
    )

    prompt = f"""
你是一名会议内容分类助手。

请根据下面的会议转录稿，判断它最适合使用哪一种整理模板。

可选模板：
{template_options}

判断原则：
- 只选择最匹配的一类；
- 如果难以明确判断，选择 general_meeting；
- confidence 为 0 到 1 的数值；
- reason 用中文简洁说明依据。

以下是会议转录稿：

{transcript_markdown}
""".strip()

    raw = run_llm(
        prompt=prompt,
        output_path=output_path,
        schema_path=schema_path,
        timeout=1200,
    )

    data = json.loads(raw)
    template = data.get("template", "general_meeting")
    confidence = data.get("confidence", 0.0)
    reason = data.get("reason", "未能提取明确判断依据。")

    if template not in allowed_templates:
        template = "general_meeting"

    if not isinstance(confidence, (int, float)):
        confidence = 0.0

    if confidence < 0.60:
        template = "general_meeting"
        reason = f"{reason}；分类置信度较低，自动回退为通用会议纪要模板。"

    classification = {
        "template": template,
        "confidence": float(confidence),
        "reason": reason,
    }

    write_json_atomic(output_path, classification)
    return classification


def load_classification(session_path: Path) -> Dict:
    path = session_path / "classification.json"
    if not path.exists():
        raise RuntimeError("缺少 classification.json")
    return json.loads(path.read_text(encoding="utf-8"))


# ============================================================
# 16. 结构化智能会议报告生成
# ============================================================

def generate_structured_report(
    transcript_markdown: str,
    classification: Dict,
    session_path: Path,
    named: bool,
) -> Dict:
    template = classification["template"]
    template_names = get_template_names()
    template_guidance = get_template_guidance()
    schema_path = ensure_report_schema()

    filename = "report_named.json" if named else "report_anon.json"
    output_path = session_path / filename
    version = "named" if named else "anonymous"

    if named:
        speaker_rule = (
            "转录稿已包含真实姓名或已更新的说话人身份。"
            "请在 speaker_insights、行动项和观点归纳中优先使用真实身份。"
        )
    else:
        speaker_rule = (
            "转录稿中的发言者仍为“说话人1”“说话人2”等匿名标签。"
            "不得猜测真实姓名，必须保留匿名标签。"
        )

    prompt = f"""
你是一名高水平会议分析与纪要整理助手。
请将下面的会议转录稿整理为一份“智能会议报告”的结构化 JSON。

会议类型：
{template} / {template_names.get(template, "通用会议纪要")}

该类型的整理重点：
{template_guidance.get(template, "以结论、行动项和讨论主题为主线整理会议内容。")}

报告版本：
{version}

必须遵守：
1. 严格依据转录稿，不要编造不存在的信息；
2. 不要虚构负责人、时间节点、决策或专家观点；
3. 原文没有明确的信息写“待确认”；
4. {speaker_rule}
5. 输出应服务于“快速读懂会议”，而不是机械压缩原文；
6. 语言应凝练、正式、接近飞书/PLAUD 会议纪要：先给总览，再给后续安排、议题复盘和关键决策；
7. 行动项要尽量可执行；
8. open_questions 应提炼真正尚未解决的问题，而不是重复摘要；
9. speaker_insights 应反映不同说话人的代表性观点；
10. report_notes 至少包含两条：
    - 本报告基于录音转写与 AI 整理生成；
    - 正式使用前建议人工核对关键信息。

关于 report_title：
- 应根据内容拟定一个自然、正式的标题；
- 不要使用“录音1”“会议材料”等泛泛标题；
- 如内容不足以判断，可用“会议纪要”。

关于 one_sentence_takeaway：
- 用一句话概括整场会议最重要的结论；
- 应类似报告首页的“核心判断”。

关于 executive_summary：
- 150–250字；
- 适合放在报告首页的摘要卡中；
- 不要堆砌每个细节，优先说明会议背景、核心结论、后续动作。

关于 key_conclusions / discussion_topics / action_items：
- key_conclusions 提炼真正的结论、决策、共识或方向，不要把所有议题都列为结论；
- discussion_topics 适合按“章节/议题”组织，每个议题应有一句摘要和 2–5 个要点；
- action_items 应类似“后续安排”，任务描述要完整，负责人或时间不明确时写“待确认”。

以下是会议转录稿：

{transcript_markdown}
""".strip()

    raw = run_llm(
        prompt=prompt,
        output_path=output_path,
        schema_path=schema_path,
        timeout=3000,
    )

    report = json.loads(raw)

    # 强制与已判定会议类型保持一致，避免结构化输出偶发漂移。
    report["meeting_type"] = template
    report["version"] = version

    # 指标用数组真实长度覆盖，避免模型计数偶发不一致。
    report["key_metrics"] = {
        "conclusion_count": len(report.get("key_conclusions", [])),
        "action_item_count": len(report.get("action_items", [])),
        "open_question_count": len(report.get("open_questions", [])),
    }

    write_json_atomic(output_path, report)
    return report


def render_report_for_feishu(report: Dict) -> str:
    lines = []

    lines.append(f"【{report.get('report_title', '会议纪要')}】")
    lines.append("")
    lines.append("一、会议一眼看懂")
    lines.append(report.get("one_sentence_takeaway", "待确认"))
    lines.append("")

    lines.append("二、执行摘要")
    lines.append(report.get("executive_summary", "待确认"))
    lines.append("")

    metrics = report.get("key_metrics", {})
    lines.append(
        f"三、概览指标："
        f"核心结论 {metrics.get('conclusion_count', 0)} 项 / "
        f"行动项 {metrics.get('action_item_count', 0)} 项 / "
        f"待确认问题 {metrics.get('open_question_count', 0)} 项"
    )
    lines.append("")

    conclusions = report.get("key_conclusions", [])
    if conclusions:
        lines.append("四、核心结论")
        for idx, item in enumerate(conclusions, start=1):
            lines.append(f"{idx}. {item.get('title', '')}")
            detail = item.get("detail", "").strip()
            if detail:
                lines.append(f"   {detail}")
        lines.append("")

    actions = report.get("action_items", [])
    if actions:
        lines.append("五、行动项")
        for idx, item in enumerate(actions, start=1):
            lines.append(
                f"{idx}. [{item.get('priority', '待确认')}] "
                f"{item.get('task', '')} "
                f"｜负责人：{item.get('owner', '待确认')} "
                f"｜时间：{item.get('deadline', '待确认')}"
            )
            notes = item.get("notes", "").strip()
            if notes:
                lines.append(f"   备注：{notes}")
        lines.append("")

    questions = report.get("open_questions", [])
    if questions:
        lines.append("六、待确认问题")
        for idx, item in enumerate(questions, start=1):
            lines.append(f"{idx}. {item.get('question', '')}")
        lines.append("")

    return "\n".join(lines).strip()


# ============================================================
# 17. 正式纪要文件发送
# ============================================================

def generate_and_send_formal_minutes_files(
    message_id: str,
    report: Dict,
    classification: Dict,
    session_path: Path,
    named: bool,
    speaker_map: Dict[str, str],
    requested_formats: Optional[set[str]] = None,
) -> Tuple[Path, Optional[Path], Path, Optional[Path]]:
    version_name = "实名版" if named else "匿名版"
    requested_formats = requested_formats or {"docx", "html"}

    write_session_runtime_status(
        task_status="processing",
        stage="generating_docx",
        message=f"正在生成{version_name} DOCX",
        session_path=session_path,
    )
    docx_path = generate_formal_minutes_docx(
        report=report,
        classification=classification,
        session_path=session_path,
        named=named,
        speaker_map=speaker_map,
    )

    write_session_runtime_status(
        task_status="processing",
        stage="generating_report_exports",
        message=f"正在生成{version_name} HTML",
        session_path=session_path,
        latest_docx=docx_path,
    )
    html_path = generate_formal_minutes_html(
        report=report,
        output_path=docx_path.with_suffix(".html"),
        named=named,
        speaker_map=speaker_map,
    )
    md_path: Optional[Path] = None
    pdf_path: Optional[Path] = None

    if "md" in requested_formats:
        md_path = generate_formal_minutes_markdown(
            report=report,
            output_path=docx_path.with_suffix(".md"),
            named=named,
            speaker_map=speaker_map,
        )

    if "pdf" in requested_formats:
        write_session_runtime_status(
            task_status="processing",
            stage="generating_pdf",
            message=f"正在生成{version_name} PDF",
            session_path=session_path,
            latest_docx=docx_path,
            latest_html=html_path,
            latest_md=md_path,
        )
        pdf_path = convert_docx_to_pdf(docx_path)

    write_session_runtime_status(
        task_status="processing",
        stage="uploading_to_feishu",
        message=f"正在回传{version_name} HTML/DOCX 到飞书",
        session_path=session_path,
        latest_docx=docx_path,
        latest_pdf=pdf_path,
        latest_html=html_path,
        latest_md=md_path,
    )
    reply_file(message_id, html_path)
    reply_file(message_id, docx_path)
    if pdf_path:
        reply_file(message_id, pdf_path)
    if md_path:
        reply_file(message_id, md_path)

    done_message = (
        "实名版会议纪要已生成"
        if named
        else "匿名版会议纪要已生成，可继续补充说话人身份"
    )
    write_session_runtime_status(
        task_status="done",
        stage="done",
        message=done_message,
        session_path=session_path,
        latest_docx=docx_path,
        latest_pdf=pdf_path,
        latest_html=html_path,
        latest_md=md_path,
    )
    write_meeting_done_event(
        session_path=session_path,
        report=report,
        docx_path=docx_path,
        pdf_path=pdf_path,
        html_path=html_path,
        md_path=md_path,
        named=named,
    )

    return docx_path, pdf_path, html_path, md_path


def parse_follow_up_export_request(text: str) -> set[str]:
    normalized = text.lower().replace(" ", "")
    formats: set[str] = set()
    if any(keyword in normalized for keyword in ["pdf", "补发pdf", "发送pdf", "要pdf"]):
        formats.add("pdf")
    if any(keyword in normalized for keyword in ["md", "markdown", "补发md", "发送md", "要md"]):
        formats.add("md")
    return formats


def append_requested_report_exports(
    message_id: str,
    requested_formats: set[str],
    session_scope: Optional[str] = None,
) -> None:
    session_path = get_latest_session(session_scope=session_scope)
    if session_path is None:
        reply_text(message_id, "当前没有可追加导出的最近一次会议。")
        return

    named = (session_path / "report_named.json").exists()
    report_path = session_path / ("report_named.json" if named else "report_anon.json")
    if not report_path.exists():
        reply_text(message_id, "最近一次会议尚未生成正式报告。")
        return

    report = json.loads(report_path.read_text(encoding="utf-8"))
    speaker_map = load_speaker_map(session_path) if (session_path / "speaker_map.json").exists() else {}
    version_name = "实名版" if named else "匿名版"
    docx_candidates = sorted(session_path.glob(f"*{version_name}*.docx"))
    html_candidates = sorted(session_path.glob(f"*{version_name}*.html"))
    docx_path = docx_candidates[-1] if docx_candidates else None
    html_path = html_candidates[-1] if html_candidates else None

    if docx_path is None or html_path is None:
        classification = load_classification(session_path)
        docx_path, _, html_path, _ = generate_and_send_formal_minutes_files(
            message_id=message_id,
            report=report,
            classification=classification,
            session_path=session_path,
            named=named,
            speaker_map=speaker_map,
            requested_formats={"docx", "html"},
        )

    generated_paths: list[Path] = []
    md_path: Optional[Path] = None
    pdf_path: Optional[Path] = None

    if "md" in requested_formats:
        md_path = docx_path.with_suffix(".md")
        if not md_path.exists():
            md_path = generate_formal_minutes_markdown(
                report=report,
                output_path=md_path,
                named=named,
                speaker_map=speaker_map,
            )
        generated_paths.append(md_path)

    if "pdf" in requested_formats:
        pdf_path = docx_path.with_suffix(".pdf")
        if not pdf_path.exists():
            pdf_path = convert_docx_to_pdf(docx_path)
        generated_paths.append(pdf_path)

    if not generated_paths:
        reply_text(message_id, "请明确需要追加 PDF、MD 或两者。")
        return

    write_session_runtime_status(
        task_status="done",
        stage="done",
        message="已追加导出 " + " / ".join(path.suffix.upper().lstrip(".") for path in generated_paths),
        session_path=session_path,
        latest_docx=docx_path,
        latest_pdf=pdf_path,
        latest_html=html_path,
        latest_md=md_path,
    )
    reply_text(
        message_id,
        "已追加生成并发送：" + "、".join(path.suffix.upper().lstrip(".") for path in generated_paths),
    )
    for path in generated_paths:
        reply_file(message_id, path)


# ============================================================
# 20. 构建提示文本
# ============================================================

def build_classification_notice(classification: Dict) -> str:
    template = classification["template"]
    confidence = classification["confidence"]
    reason = classification["reason"]

    return (
        f"AI 已自动选择模板：\n"
        f"【{get_template_names().get(template, '通用会议纪要')}】\n"
        f"判断依据：{reason}\n"
        f"置信度：{confidence:.2f}"
    )


def build_detected_speakers_notice(speaker_map: Dict[str, str]) -> str:
    visible_names = [
        value
        for raw, value in speaker_map.items()
        if raw != "UNKNOWN" and value not in {"说话人未知", "未知说话人"}
    ]

    lines = ["当前检测到的说话人："]
    for name in visible_names:
        lines.append(f"- {name}")

    lines.extend(["", "如需补充真实身份，请回复："])
    for name in visible_names:
        lines.append(f"{name}=真实姓名")

    lines.extend(["", "例如：", "说话人1=我", "说话人2=张老师"])
    return "\n".join(lines)


# ============================================================
# 21. 完整音频处理主流程
# ============================================================

def load_or_classify_meeting(transcript_markdown: str, session_path: Path) -> Dict:
    if (session_path / "classification.json").exists():
        return load_classification(session_path)

    return classify_meeting_type(
        transcript_markdown=transcript_markdown,
        session_path=session_path,
    )


def ensure_speaker_map_for_text_session(session_path: Path, merged_segments: List[Dict]) -> Dict[str, str]:
    if (session_path / "speaker_map.json").exists():
        return load_speaker_map(session_path)

    speakers = []
    for seg in merged_segments:
        speaker = seg.get("speaker", "TEXT")
        if speaker not in speakers:
            speakers.append(speaker)

    if speakers == ["TEXT"]:
        speaker_map = {"TEXT": "转录文本"}
    else:
        speaker_map = {speaker: speaker for speaker in speakers}

    save_speaker_map(session_path, speaker_map)
    return speaker_map


def generate_report_from_transcript(
    message_id: str,
    session_path: Path,
    transcript_markdown: str,
    speaker_map: Dict[str, str],
    named: bool = False,
    reuse_notice: str = "",
) -> None:
    version_name = "实名版" if named else "匿名版"

    if reuse_notice:
        reply_text(message_id, reuse_notice)

    write_session_runtime_status(
        task_status="processing",
        stage="classifying_meeting",
        message="正在识别会议类型",
        session_path=session_path,
    )
    classification = load_or_classify_meeting(
        transcript_markdown=transcript_markdown,
        session_path=session_path,
    )

    write_session_runtime_status(
        task_status="processing",
        stage="generating_report",
        message=f"正在生成{version_name}会议纪要",
        session_path=session_path,
    )
    report = generate_structured_report(
        transcript_markdown=transcript_markdown,
        classification=classification,
        session_path=session_path,
        named=named,
    )
    summary_text = render_report_for_feishu(report)
    summary_name = "summary_named.txt" if named else "summary_anon.txt"
    atomic_write_text(session_path / summary_name, summary_text)

    reply_text(message_id, build_classification_notice(classification))
    if speaker_map:
        reply_text(message_id, build_detected_speakers_notice(speaker_map))

    reply_text(message_id, f"已生成{version_name}智能会议摘要。完整转录稿默认不在对话框中展开，可在会议目录中查看 transcript_*.md。")
    reply_long_text(message_id, summary_text)

    generate_and_send_formal_minutes_files(
        message_id=message_id,
        report=report,
        classification=classification,
        session_path=session_path,
        named=named,
        speaker_map=speaker_map,
    )


def process_text_transcript_material(
    message_id: str,
    text: str,
    source_name: str = "transcript.txt",
    reuse_if_available: bool = True,
    session_scope: Optional[str] = None,
) -> None:
    session_path: Optional[Path] = None
    downloaded_audio: Optional[Path] = None
    try:
        normalized = normalize_uploaded_transcript_text(text, title=Path(source_name).stem or "上传的转录文字材料")
        source_hash = transcript_text_sha256(text)

        if reuse_if_available:
            reusable = find_reusable_session(
                source_hash,
                "transcript_text",
                session_scope=session_scope,
            )
            if reusable is not None:
                transcript_anon = (reusable / "transcript_anon.md").read_text(encoding="utf-8")
                speaker_map = load_speaker_map(reusable) if (reusable / "speaker_map.json").exists() else {}
                set_latest_session(reusable, session_scope=session_scope)
                write_session_runtime_status(
                    task_status="processing",
                    stage="reusing_transcript",
                    message="检测到相同转录文字已处理过，正在复用转录稿生成纪要",
                    session_path=reusable,
                )
                generate_report_from_transcript(
                    message_id=message_id,
                    session_path=reusable,
                    transcript_markdown=transcript_anon,
                    speaker_map=speaker_map,
                    named=False,
                    reuse_notice="检测到相同的转录文字材料已处理过，已跳过文本导入，直接重新汇编纪要和报告。",
                )
                return

        session_path = create_text_session(source_name, session_scope=session_scope)
        write_session_metadata(
            session_path,
            {
                "source_kind": "transcript_text",
                "source_name": source_name,
                "source_sha256": source_hash,
                "created_at": runtime_timestamp(),
                "session_scope_sha256": session_scope_digest(session_scope),
            },
        )
        atomic_write_text(session_path / "uploaded_transcript.txt", text.strip())
        atomic_write_text(session_path / "transcript_anon.md", normalized)

        merged_segments = create_text_segments_from_transcript(text, session_path)
        speaker_map = ensure_speaker_map_for_text_session(session_path, merged_segments)

        generate_report_from_transcript(
            message_id=message_id,
            session_path=session_path,
            transcript_markdown=normalized,
            speaker_map=speaker_map,
            named=False,
            reuse_notice="已收到转录文字材料，将跳过音频转写，直接生成会议纪要和报告文件。",
        )

    except Exception as e:
        error_msg = f"处理转录文字材料失败：{str(e)}"
        print("[Transcript Text Error]", error_msg)
        write_session_runtime_status(
            task_status="error",
            stage="error",
            message=error_msg,
            session_path=session_path,
        )
        reply_text(message_id, error_msg)
def process_audio_message(
    message_id: str,
    message_type: str,
    content: Dict,
    command_text: str = "",
    resource_message_id: Optional[str] = None,
    session_scope: Optional[str] = None,
) -> None:
    session_path: Optional[Path] = None
    downloaded_audio: Optional[Path] = None
    try:
        file_key = content.get("file_key")
        file_name = (
            content.get("file_name")
            or content.get("name")
            or f"{message_type}_{uuid.uuid4().hex}.bin"
        )

        if not file_key:
            write_runtime_status(
                task_status="error",
                stage="error",
                message="未能读取 file_key，无法下载录音或文件",
            )
            reply_text(message_id, "未能读取 file_key，无法下载录音或文件。")
            print("[Media] content =", content)
            return

        force_retranscribe = is_force_retranscribe(command_text)

        write_runtime_status(
            task_status="processing",
            stage="received_audio",
            message=f"已收到文件：{file_name}",
        )
        if force_retranscribe:
            reply_text(message_id, "已收到文件，并检测到重新转录要求，将重新下载并完整转写。")
        else:
            reply_text(message_id, "已收到文件。若检测到已有转录结果，将直接复用并生成纪要；否则会进行转写。")

        write_runtime_status(
            task_status="processing",
            stage="downloading_audio",
            message=f"正在下载录音：{file_name}",
        )
        downloaded_audio = download_message_resource(
            message_id=resource_message_id or message_id,
            file_key=file_key,
            filename=file_name,
            resource_type="audio" if message_type == "audio" else "file",
        )

        if is_text_material_file(file_name):
            text = read_text_file(downloaded_audio)
            process_text_transcript_material(
                message_id=message_id,
                text=text,
                source_name=file_name,
                reuse_if_available=True,
                session_scope=session_scope,
            )
            return

        if not is_audio_material_file(file_name):
            reply_text(
                message_id,
                "已下载文件，但暂不确定它是音频还是转录文本。请上传 m4a/mp3/wav 等音频，或 txt/md/srt/vtt 文本材料。",
            )
            return

        audio_hash = file_sha256(downloaded_audio)
        if not force_retranscribe:
            reusable = find_reusable_session(
                audio_hash,
                "audio",
                session_scope=session_scope,
            )
            if reusable is not None:
                transcript_anon = (reusable / "transcript_anon.md").read_text(encoding="utf-8")
                speaker_map = load_speaker_map(reusable)
                set_latest_session(reusable, session_scope=session_scope)
                write_session_runtime_status(
                    task_status="processing",
                    stage="reusing_transcript",
                    message="检测到相同音频已完成转写，正在复用转录稿生成纪要",
                    session_path=reusable,
                )
                generate_report_from_transcript(
                    message_id=message_id,
                    session_path=reusable,
                    transcript_markdown=transcript_anon,
                    speaker_map=speaker_map,
                    named=False,
                    reuse_notice="检测到这段音频以前已经完成转写，本次跳过重新转录，直接重新生成会议纪要和报告文件。如需重跑 ASR，请回复或引用时写“重新转录”。",
                )
                return

        session_path = create_session(downloaded_audio, session_scope=session_scope)
        session_audio = session_path / downloaded_audio.name
        write_session_metadata(
            session_path,
            {
                "source_kind": "audio",
                "source_name": file_name,
                "source_sha256": audio_hash,
                "created_at": runtime_timestamp(),
                "session_scope_sha256": session_scope_digest(session_scope),
            },
        )

        write_session_runtime_status(
            task_status="processing",
            stage="converting_audio",
            message="正在转换音频",
            session_path=session_path,
        )
        analysis_audio = convert_audio_to_wav_16k_mono(
            input_audio=session_audio,
            session_path=session_path,
        )

        write_session_runtime_status(
            task_status="processing",
            stage="diarization",
            message="正在进行说话人分离",
            session_path=session_path,
        )
        diarization_segments = diarize_audio(
            audio_path=analysis_audio,
            session_path=session_path,
        )

        write_session_runtime_status(
            task_status="processing",
            stage="transcribing",
            message="正在语音转写",
            session_path=session_path,
        )
        transcript_segments = transcribe_audio(
            audio_path=analysis_audio,
            session_path=session_path,
        )

        write_session_runtime_status(
            task_status="processing",
            stage="aligning_speakers",
            message="正在对齐说话人与转录文本",
            session_path=session_path,
        )
        merged_segments = assign_speakers_to_transcript(
            transcript_segments=transcript_segments,
            diarization_segments=diarization_segments,
            session_path=session_path,
        )

        speaker_map = build_default_speaker_map(
            merged_segments=merged_segments,
            session_path=session_path,
        )

        transcript_anon = save_transcript_versions(
            session_path=session_path,
            merged_segments=merged_segments,
            speaker_map=speaker_map,
            named=False,
        )

        generate_report_from_transcript(
            message_id=message_id,
            session_path=session_path,
            transcript_markdown=transcript_anon,
            speaker_map=speaker_map,
            named=False,
        )

    except Exception as e:
        error_msg = f"处理录音失败：{str(e)}"
        print("[Error]", error_msg)
        write_session_runtime_status(
            task_status="error",
            stage="error",
            message=error_msg,
            session_path=session_path,
        )
        reply_text(message_id, error_msg)
    finally:
        FEISHU_IO.cleanup_download(downloaded_audio)


# ============================================================
# 22. 说话人身份更新
# ============================================================

def parse_speaker_mapping_update(text: str) -> Dict[str, str]:
    updates = {}
    lines = re.split(r"[\n；;]+", text.strip())

    for line in lines:
        line = line.strip()
        if not line:
            continue

        match = re.match(r"^(说话人\d+)\s*=\s*(.+)$", line)
        if match:
            old_name = match.group(1).strip()
            new_name = match.group(2).strip()
            if new_name:
                updates[old_name] = new_name

    return updates


def apply_speaker_mapping_updates(
    speaker_map: Dict[str, str],
    updates: Dict[str, str],
) -> Tuple[Dict[str, str], List[str]]:
    reverse_map = {v: k for k, v in speaker_map.items()}
    changed = []

    for anon_name, real_name in updates.items():
        raw_speaker = reverse_map.get(anon_name)
        if raw_speaker:
            speaker_map[raw_speaker] = real_name
            changed.append(f"{anon_name} → {real_name}")

    return speaker_map, changed


def regenerate_named_outputs(
    message_id: str,
    updates: Dict[str, str],
    session_scope: Optional[str] = None,
) -> None:
    session_path: Optional[Path] = None
    try:
        session_path = get_latest_session(session_scope=session_scope)
        if session_path is None:
            reply_text(message_id, "当前没有可更新的最近一次录音任务。")
            return

        speaker_map = load_speaker_map(session_path)
        speaker_map, changed = apply_speaker_mapping_updates(
            speaker_map=speaker_map,
            updates=updates,
        )

        if not changed:
            reply_text(
                message_id,
                "未找到可更新的说话人标签。请使用例如“说话人1=我”的格式。",
            )
            return

        save_speaker_map(session_path, speaker_map)

        write_session_runtime_status(
            task_status="processing",
            stage="aligning_speakers",
            message="正在更新说话人身份",
            session_path=session_path,
        )
        reply_text(
            message_id,
            "已更新说话人身份：\n"
            + "\n".join(f"- {x}" for x in changed)
            + "\n\n开始重新生成实名版转录稿与智能会议报告。",
        )

        merged_segments = load_merged_segments(session_path)
        transcript_named = save_transcript_versions(
            session_path=session_path,
            merged_segments=merged_segments,
            speaker_map=speaker_map,
            named=True,
        )

        classification = load_classification(session_path)

        write_session_runtime_status(
            task_status="processing",
            stage="generating_report",
            message="正在生成实名版会议纪要",
            session_path=session_path,
        )
        report_named = generate_structured_report(
            transcript_markdown=transcript_named,
            classification=classification,
            session_path=session_path,
            named=True,
        )
        summary_named_text = render_report_for_feishu(report_named)
        atomic_write_text(session_path / "summary_named.txt", summary_named_text)

        reply_text(message_id, "已生成更新身份后的智能会议摘要。完整转录稿默认不在对话框中展开，可在会议目录中查看 transcript_named.md。")
        reply_long_text(message_id, summary_named_text)

        generate_and_send_formal_minutes_files(
            message_id=message_id,
            report=report_named,
            classification=classification,
            session_path=session_path,
            named=True,
            speaker_map=speaker_map,
        )

    except Exception as e:
        error_msg = f"更新说话人身份失败：{str(e)}"
        print("[Speaker Update Error]", error_msg)
        write_session_runtime_status(
            task_status="error",
            stage="error",
            message=error_msg,
            session_path=session_path,
        )
        reply_text(message_id, error_msg)


# ============================================================
# 23. 查看当前说话人映射
# ============================================================

def show_current_speaker_mapping(
    message_id: str,
    session_scope: Optional[str] = None,
) -> None:
    session_path = get_latest_session(session_scope=session_scope)
    if session_path is None:
        reply_text(message_id, "当前没有最近一次录音任务。")
        return

    speaker_map = load_speaker_map(session_path)

    lines = ["最近一次录音的说话人映射："]
    for raw_speaker, display_name in speaker_map.items():
        lines.append(f"- {raw_speaker} → {display_name}")

    reply_text(message_id, "\n".join(lines))


# ============================================================
# 24. 文本消息处理
# ============================================================

def handle_text_message(
    message_id: str,
    text: str,
    content: Optional[Dict] = None,
    message_obj=None,
    session_scope: Optional[str] = None,
) -> None:
    text = text.strip()
    content = content or {}

    if not text:
        reply_text(message_id, "收到空文本。")
        return

    reference_request = is_regenerate_report_request(text) or is_force_retranscribe(text)
    referenced_payload = None
    if reference_request:
        current_chat_id = str(getattr(message_obj, "chat_id", "") or "").strip()
        try:
            referenced_payload = get_referenced_message_payload(
                content,
                message_obj,
                expected_chat_id=current_chat_id,
            )
        except ReferencedMessageAuthorizationError:
            reply_text(
                message_id,
                "无法读取引用内容，请确认引用消息位于当前会话后重试。",
            )
            return

    if referenced_payload and reference_request:
        ref_type = referenced_payload.get("message_type", "")
        ref_content = referenced_payload.get("content", {})
        ref_message_id = referenced_payload.get("message_id", "")

        if ref_type in {"audio", "file"}:
            if is_force_retranscribe(text):
                reply_text(message_id, "已读取你引用的文件消息，将重新下载并完整转写后生成会议纪要。")
            else:
                reply_text(message_id, "已读取你引用的文件消息；如已有转录结果会直接复用，否则会先转写再生成会议纪要。")
            process_audio_message(
                message_id=message_id,
                message_type=ref_type,
                content=ref_content,
                command_text=text,
                resource_message_id=ref_message_id,
                session_scope=session_scope,
            )
            return

        if ref_type == "text":
            quoted_text = ref_content.get("text", "")
            if looks_like_transcript_text(quoted_text):
                reply_text(message_id, "已读取你引用的转录文字，将直接生成会议纪要和报告文件。")
                process_text_transcript_material(
                    message_id=message_id,
                    text=quoted_text,
                    source_name="quoted_transcript.txt",
                    reuse_if_available=True,
                    session_scope=session_scope,
                )
                return

        reply_text(message_id, "已看到引用消息，但它不是可处理的音频文件或转录文字。请引用音频/文件消息，或直接上传 txt/md/srt/vtt/csv。")
        return

    if text in {"帮助", "help", "/help"}:
        help_text = """
我是你的本机会议转写与智能纪要助手。

你可以：
1. 直接发送会议录音文件；
2. 上传 txt/md/srt/vtt/csv 转录文字材料，跳过语音转写直接生成纪要；
3. 引用已经上传过的音频并回复“重新生成会议纪要”，如已有转录结果会直接复用；
4. 如确实需要重跑 ASR，请引用音频并写“重新转录”；
5. 重复上传相同音频或文字材料时，默认跳过重复转写，只重新汇编纪要和报告；
6. 我会自动：
   - 下载音频
   - 说话人分离
   - 完整转写
   - 自动判断会议类型
   - 生成智能会议摘要
   - 默认生成并发送 HTML / DOCX 正式纪要
7. 首次输出匿名版：
   - 说话人1 / 说话人2 / 说话人3
8. 你可以随后回复：
   说话人1=我
   说话人2=张老师
9. 我会重新生成：
   - 基于真实身份的智能会议摘要
   - 实名版 HTML / DOCX 正式纪要

默认不会在对话框展开完整转录稿，转录稿会保存到会议目录。

其他命令：
- 查看说话人
- 追加 PDF
- 追加 MD
- 追加 PDF 和 MD
""".strip()
        reply_text(message_id, help_text)
        return

    if text == "查看说话人":
        show_current_speaker_mapping(message_id, session_scope=session_scope)
        return

    requested_exports = parse_follow_up_export_request(text)
    if requested_exports:
        append_requested_report_exports(
            message_id,
            requested_exports,
            session_scope=session_scope,
        )
        return

    speaker_updates = parse_speaker_mapping_update(text)
    if speaker_updates:
        regenerate_named_outputs(
            message_id,
            speaker_updates,
            session_scope=session_scope,
        )
        return

    if looks_like_transcript_text(text):
        process_text_transcript_material(
            message_id,
            text,
            "pasted_transcript.txt",
            True,
            session_scope=session_scope,
        )
        return

    reply_text(
        message_id,
        "已收到文本。你可以发送音频、上传 txt/md/srt/vtt/csv 转录材料，或引用已上传音频并回复“重新生成会议纪要”。",
    )


# ============================================================
# 25. 飞书事件入口
# ============================================================

def feishu_session_scope(data: P2ImMessageReceiveV1) -> str:
    message = data.event.message
    chat_id = str(getattr(message, "chat_id", "") or "").strip()
    if chat_id:
        return f"feishu:chat:{chat_id}"

    sender = getattr(data.event, "sender", None)
    sender_id = getattr(sender, "sender_id", None)
    for attribute in ("open_id", "user_id", "union_id"):
        value = str(getattr(sender_id, attribute, "") or "").strip()
        if value:
            return f"feishu:sender:{attribute}:{value}"

    return f"feishu:message:{message.message_id}"

def on_message_receive(data: P2ImMessageReceiveV1) -> None:
    try:
        message = data.event.message
        message_id = message.message_id
        message_type = message.message_type
        session_scope = feishu_session_scope(data)

        if not MESSAGE_DEDUPLICATOR.claim(message_id):
            print(f"[Dedup] 跳过重复消息：{message_id}")
            return

        raw_content = message.content or "{}"
        content = json.loads(raw_content)

        print(f"[Feishu] 收到消息：type={message_type}, id={message_id}")

        if message_type == "text":
            text = content.get("text", "")
            accepted = MESSAGE_TASKS.submit(
                handle_text_message,
                message_id,
                text,
                content,
                message,
                session_scope,
                principal=session_scope,
            )
            if not accepted:
                MESSAGE_DEDUPLICATOR.release(message_id)
                reply_text(message_id, "当前会话待处理任务较多，请稍后重新发送。")

        elif message_type in {"audio", "file"}:
            accepted = MESSAGE_TASKS.submit(
                process_audio_message,
                message_id,
                message_type,
                content,
                "",
                None,
                session_scope,
                principal=session_scope,
            )
            if not accepted:
                MESSAGE_DEDUPLICATOR.release(message_id)
                reply_text(message_id, "当前会话待处理任务较多，请稍后重新发送。")

        else:
            reply_text(
                message_id,
                f"暂不支持这种消息类型：{message_type}。请发送音频文件。",
            )

    except Exception as e:
        print("[Event Error]", str(e))


# ============================================================
# 26. 启动飞书长连接
# ============================================================

event_handler = (
    lark.EventDispatcherHandler.builder(
        FEISHU_APP_ID,
        FEISHU_APP_SECRET,
    )
    .register_p2_im_message_receive_v1(on_message_receive)
    .build()
)


def main() -> None:
    RUNTIME_STATUS.write_idle_if_no_active_task()
    print("[Bot] 启动飞书长连接机器人")
    print("[Bot] 请确认：")
    print("1. 飞书应用已发布")
    print("2. 已启用机器人能力")
    print("3. 已订阅“接收消息 v2.0”")
    print("4. 机器人已加入私聊或测试群")
    print(f"5. 纪要生成后端可用（{llm_runtime_description()}）")
    print("6. Hugging Face token 可用，pyannote 模型条款已接受")
    print("7. LibreOffice 可用，用于生成 PDF")

    ws_client = lark.ws.Client(
        FEISHU_APP_ID,
        FEISHU_APP_SECRET,
        event_handler=event_handler,
        log_level=lark.LogLevel.INFO,
    )
    ws_client.start()


if __name__ == "__main__":
    main()
