import json
import subprocess
from pathlib import Path
from typing import Dict, Optional

from meetingbot_config import (
    CODEX_BIN,
    SCHEMA_DIR,
    get_allowed_templates,
    get_template_descriptions,
    get_template_guidance,
    get_template_names,
)


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

    schema_path.write_text(
        json.dumps(schema, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
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

    schema_path.write_text(
        json.dumps(schema, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return schema_path


def run_codex(
    prompt: str,
    output_path: Path,
    schema_path: Optional[Path] = None,
    timeout: int = 2400,
) -> str:
    cmd = [
        CODEX_BIN,
        "exec",
        "--skip-git-repo-check",
        "--sandbox",
        "read-only",
        "--ephemeral",
    ]

    if schema_path is not None:
        cmd.extend(["--output-schema", str(schema_path)])

    cmd.extend(["--output-last-message", str(output_path), "-"])

    result = subprocess.run(
        cmd,
        input=prompt,
        text=True,
        capture_output=True,
        timeout=timeout,
    )

    if result.returncode != 0:
        raise RuntimeError(
            "Codex 执行失败。\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )

    if not output_path.exists():
        raise RuntimeError(f"Codex 未生成输出文件：{output_path.name}")

    return output_path.read_text(encoding="utf-8").strip()


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

    raw = run_codex(
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
    output_path.write_text(
        json.dumps(classification, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return classification


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

    raw = run_codex(
        prompt=prompt,
        output_path=output_path,
        schema_path=schema_path,
        timeout=3000,
    )
    report = json.loads(raw)
    report["meeting_type"] = template
    report["version"] = version
    report["key_metrics"] = {
        "conclusion_count": len(report.get("key_conclusions", [])),
        "action_item_count": len(report.get("action_items", [])),
        "open_question_count": len(report.get("open_questions", [])),
    }
    output_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return report
