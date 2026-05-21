import json
import os
import shutil
from pathlib import Path

from dotenv import load_dotenv


load_dotenv()

FEISHU_APP_ID = os.getenv("FEISHU_APP_ID", "").strip()
FEISHU_APP_SECRET = os.getenv("FEISHU_APP_SECRET", "").strip()
HF_TOKEN = os.getenv("HF_TOKEN", "").strip()

ASR_ENGINE = os.getenv("ASR_ENGINE", "faster-whisper").strip() or "faster-whisper"
ASR_MODEL = os.getenv("ASR_MODEL", "small").strip()
ASR_LANGUAGE = os.getenv("ASR_LANGUAGE", "zh").strip()
DIARIZATION_MODEL = os.getenv(
    "DIARIZATION_MODEL",
    "pyannote/speaker-diarization-community-1",
).strip()


def resolve_tool_path(raw_value: str, fallback: str) -> str:
    value = raw_value.strip() or fallback
    if "/" in value:
        return value
    resolved = shutil.which(value)
    if resolved:
        return resolved
    for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]:
        candidate = Path(directory) / value
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate)
    return value


CODEX_BIN = resolve_tool_path(os.getenv("CODEX_BIN", "codex"), "codex")
FFMPEG_BIN = resolve_tool_path(os.getenv("FFMPEG_BIN", "ffmpeg"), "ffmpeg")
REPORT_BODY_FONT = os.getenv("REPORT_BODY_FONT", "PingFang SC").strip() or "PingFang SC"
REPORT_HEADING_FONT = os.getenv("REPORT_HEADING_FONT", REPORT_BODY_FONT).strip() or REPORT_BODY_FONT

if not FEISHU_APP_ID:
    raise ValueError("FEISHU_APP_ID 为空，请检查 .env")
if not FEISHU_APP_ID.startswith("cli_"):
    raise ValueError(f"FEISHU_APP_ID 看起来不正确：{FEISHU_APP_ID}")
if not FEISHU_APP_SECRET:
    raise ValueError("FEISHU_APP_SECRET 为空，请检查 .env")
if not HF_TOKEN:
    raise ValueError("HF_TOKEN 为空，请检查 .env")

BASE_DIR = Path(__file__).resolve().parent


def resolve_storage_dir(raw_value: str, default_name: str) -> Path:
    raw_value = raw_value.strip()
    if not raw_value:
        return BASE_DIR / default_name
    path = Path(raw_value).expanduser()
    return path if path.is_absolute() else BASE_DIR / path


DOWNLOAD_DIR = resolve_storage_dir(os.getenv("RECORDINGS_DIR", ""), "downloads")
SESSION_DIR = resolve_storage_dir(os.getenv("MEETING_OUTPUT_DIR", ""), "sessions")
SCHEMA_DIR = BASE_DIR / "schemas"
TMP_DIR = BASE_DIR / "tmp"
RUNTIME_DIR = BASE_DIR / "runtime"
RUNTIME_EVENTS_DIR = RUNTIME_DIR / "events"
RUNTIME_STATUS_FILE = RUNTIME_DIR / "status.json"
LIBRARY_DIR = BASE_DIR / "library"
TEMPLATE_CONFIG_FILE = LIBRARY_DIR / "meeting_templates.json"

for directory in [
    DOWNLOAD_DIR,
    SESSION_DIR,
    SCHEMA_DIR,
    TMP_DIR,
    RUNTIME_DIR,
    RUNTIME_EVENTS_DIR,
    LIBRARY_DIR,
]:
    directory.mkdir(parents=True, exist_ok=True)

DEFAULT_TEMPLATE_DEFINITIONS = [
    {
        "id": "general_meeting",
        "name": "通用会议纪要",
        "category": "通用",
        "description": "适合难以进一步归类的常规会议。",
        "guidance": "以结论、行动项、讨论主题为主线整理会议内容。",
        "isBuiltIn": True,
    },
    {
        "id": "research_discussion",
        "name": "科研讨论会",
        "category": "科研与专业",
        "description": "适合学术讨论、研究进展和方案评议。",
        "guidance": "突出研究问题、方法、证据、争议点和下一步实验。",
        "isBuiltIn": True,
    },
    {
        "id": "project_progress",
        "name": "项目推进会",
        "category": "项目与管理",
        "description": "适合项目进度、任务协调和风险跟踪。",
        "guidance": "突出里程碑、当前进展、阻塞项、责任人和下一步动作。",
        "isBuiltIn": True,
    },
    {
        "id": "expert_consultation",
        "name": "专家咨询 / 评审意见整理",
        "category": "科研与专业",
        "description": "适合专家咨询、评审会和外部意见收集。",
        "guidance": "突出专家观点、共识、分歧、建议和需要吸收的修改。",
        "isBuiltIn": True,
    },
    {
        "id": "management_meeting",
        "name": "管理工作会",
        "category": "项目与管理",
        "description": "适合部门协调、经营管理和组织议题。",
        "guidance": "突出决策、分工、时间节点、风险和跨部门协同。",
        "isBuiltIn": True,
    },
    {
        "id": "interview_summary",
        "name": "访谈 / 座谈整理",
        "category": "调研与访谈",
        "description": "适合访谈、座谈和深度交流。",
        "guidance": "突出受访者观点、代表性表述、主题归纳和待验证问题。",
        "isBuiltIn": True,
    },
    {
        "id": "parent_teacher_meeting",
        "name": "家长会 / 家校沟通",
        "category": "教育与培训",
        "description": "适合家长会、家校沟通和学生成长反馈。",
        "guidance": "突出学生表现、家校共识、待跟进问题和后续协同安排。",
        "isBuiltIn": True,
    },
    {
        "id": "legal_communication",
        "name": "法律沟通 / 合规讨论",
        "category": "法务与合规",
        "description": "适合法律咨询、合同讨论、合规风险沟通。",
        "guidance": "突出事实背景、法律问题、风险判断、待确认材料和后续动作。",
        "isBuiltIn": True,
    },
    {
        "id": "sales_conversion",
        "name": "销售转化 / 商机推进",
        "category": "销售与客户",
        "description": "适合客户需求沟通、销售跟进和转化推进。",
        "guidance": "突出客户诉求、购买信号、异议、决策链、下一步转化动作。",
        "isBuiltIn": True,
    },
    {
        "id": "customer_success",
        "name": "客户成功 / 服务复盘",
        "category": "销售与客户",
        "description": "适合客户回访、交付复盘和续约沟通。",
        "guidance": "突出使用现状、满意度、问题闭环、价值验证和续约风险。",
        "isBuiltIn": True,
    },
    {
        "id": "product_development",
        "name": "产品研发会",
        "category": "产品与研发",
        "description": "适合需求评审、方案讨论、版本计划和研发协同。",
        "guidance": "突出用户问题、需求范围、技术方案、取舍、排期和责任人。",
        "isBuiltIn": True,
    },
    {
        "id": "product_review",
        "name": "产品评审 / 设计评审",
        "category": "产品与研发",
        "description": "适合 PRD、交互、设计或上线前评审。",
        "guidance": "突出评审对象、通过项、待修改项、风险和验收标准。",
        "isBuiltIn": True,
    },
    {
        "id": "recruitment_interview",
        "name": "招聘面试 / 候选人评估",
        "category": "人力与组织",
        "description": "适合招聘面试、复试和候选人校准。",
        "guidance": "突出候选人背景、关键证据、优势、疑虑和录用建议。",
        "isBuiltIn": True,
    },
    {
        "id": "training_workshop",
        "name": "培训 / 工作坊",
        "category": "教育与培训",
        "description": "适合培训授课、共创工作坊和学习复盘。",
        "guidance": "突出目标、核心内容、参与反馈、练习结果和后续任务。",
        "isBuiltIn": True,
    },
]


def load_template_catalog() -> list[dict]:
    if TEMPLATE_CONFIG_FILE.exists():
        try:
            payload = json.loads(TEMPLATE_CONFIG_FILE.read_text(encoding="utf-8"))
            templates = payload.get("templates", [])
            normalized = [
                item
                for item in templates
                if isinstance(item, dict)
                and str(item.get("id", "")).strip()
                and str(item.get("name", "")).strip()
            ]
            if normalized:
                return normalized
        except Exception:
            pass

    return list(DEFAULT_TEMPLATE_DEFINITIONS)


def get_template_names() -> dict[str, str]:
    return {
        str(item["id"]): str(item["name"])
        for item in load_template_catalog()
    }


def get_allowed_templates() -> set[str]:
    return set(get_template_names().keys())


def get_template_descriptions() -> dict[str, str]:
    return {
        str(item["id"]): str(item.get("description", "")).strip()
        for item in load_template_catalog()
    }


def get_template_guidance() -> dict[str, str]:
    return {
        str(item["id"]): str(item.get("guidance", "")).strip()
        for item in load_template_catalog()
    }


TEMPLATE_NAMES = get_template_names()
ALLOWED_TEMPLATES = get_allowed_templates()
