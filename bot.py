import fcntl
import os
import re
import json
import time
import uuid
import threading
import subprocess
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Tuple, Optional

# Allow unsupported Apple GPU operations to fall back to CPU.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import requests
import soundfile as sf
import torch

# pyannote telemetry can block long-running background processes when its
# exporter connection becomes stale. The bot runs fully locally, so disable it.
os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "false")
os.environ.setdefault("OTEL_SDK_DISABLED", "true")

from pyannote.audio import Pipeline

import lark_oapi as lark
from lark_oapi.api.im.v1 import (
    ReplyMessageRequest,
    ReplyMessageRequestBody,
    P2ImMessageReceiveV1,
)

from chinese_text import simplify_chinese
from asr_runtime import asr_runtime_description, create_asr_model, transcribe_with_asr_model
from diarization_runtime import configure_diarization_pipeline, run_diarization_pipeline
from llm_backend import llm_runtime_description, run_llm
from speaker_naming import build_anonymous_speaker_map
from meetingbot_config import (
    ASR_LANGUAGE,
    ASR_MODEL,
    BASE_DIR,
    DIARIZATION_MODEL,
    DOWNLOAD_DIR,
    FEISHU_APP_ID,
    FEISHU_APP_SECRET,
    FFMPEG_BIN,
    HF_TOKEN,
    RUNTIME_DIR,
    RUNTIME_EVENTS_DIR,
    RUNTIME_STATUS_FILE,
    SCHEMA_DIR,
    SESSION_DIR,
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
    set_latest_session,
    transcript_text_sha256,
    write_session_metadata,
)
from transcript_material import (
    create_text_segments_from_transcript,
    normalize_uploaded_transcript_text,
)
from transcription_progress import TranscriptionProgress, audio_duration_seconds


# ============================================================
# 2. 全局状态
# ============================================================

PROCESSED_MESSAGE_IDS = set()
DIARIZATION_LOCK = threading.Lock()


def runtime_timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def session_runtime_fields(session_path: Optional[Path]) -> Dict[str, str]:
    if session_path is None:
        return {"session_id": "", "session_dir": ""}

    return {
        "session_id": session_path.name,
        "session_dir": str(session_path),
    }


def write_runtime_status(
    task_status: str,
    stage: str,
    message: str,
    session_id: str = "",
    session_dir: str = "",
    latest_pdf: str = "",
    latest_docx: str = "",
    latest_html: str = "",
    latest_md: str = "",
    service_status: str = "running",
) -> None:
    try:
        RUNTIME_DIR.mkdir(parents=True, exist_ok=True)

        payload = {
            "service_status": service_status,
            "task_status": task_status,
            "stage": stage,
            "message": message,
            "session_id": session_id,
            "session_dir": session_dir,
            "latest_pdf": latest_pdf,
            "latest_docx": latest_docx,
            "latest_html": latest_html,
            "latest_md": latest_md,
            "updated_at": runtime_timestamp(),
            "source": "feishu_bot",
        }

        tmp_path = RUNTIME_DIR / f".status_{uuid.uuid4().hex}.json.tmp"
        tmp_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        tmp_path.replace(RUNTIME_STATUS_FILE)
    except Exception as e:
        print(f"[Runtime Status] 写入失败：{e}")


def write_session_runtime_status(
    task_status: str,
    stage: str,
    message: str,
    session_path: Optional[Path],
    latest_pdf: Optional[Path] = None,
    latest_docx: Optional[Path] = None,
    latest_html: Optional[Path] = None,
    latest_md: Optional[Path] = None,
) -> None:
    fields = session_runtime_fields(session_path)
    write_runtime_status(
        task_status=task_status,
        stage=stage,
        message=message,
        session_id=fields["session_id"],
        session_dir=fields["session_dir"],
        latest_pdf=str(latest_pdf) if latest_pdf else "",
        latest_docx=str(latest_docx) if latest_docx else "",
        latest_html=str(latest_html) if latest_html else "",
        latest_md=str(latest_md) if latest_md else "",
    )


def local_meeting_task_is_alive() -> bool:
    """通过 local_meeting.lock 的 flock 判断本地新增会议任务是否仍在运行。"""
    lock_path = RUNTIME_DIR / "local_meeting.lock"
    if not lock_path.exists():
        return False

    try:
        with lock_path.open("a+", encoding="utf-8") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            return False
    except OSError:
        return False


def write_idle_runtime_status_if_no_active_task() -> None:
    # bot 启动时自身没有任务在跑；状态若为 processing，只有当持锁的
    # 本地新增会议进程确实存活时才保留，否则视为上次任务崩溃遗留的
    # 陈旧状态，重置为 idle，避免状态栏永远显示"处理中"。
    try:
        if RUNTIME_STATUS_FILE.exists():
            current = json.loads(RUNTIME_STATUS_FILE.read_text(encoding="utf-8"))
            if (
                current.get("task_status") == "processing"
                and local_meeting_task_is_alive()
            ):
                return
    except (OSError, json.JSONDecodeError):
        pass

    write_runtime_status(
        task_status="idle",
        stage="idle",
        message="机器人后台服务运行中",
    )


def write_meeting_done_event(
    session_path: Path,
    report: Dict,
    docx_path: Path,
    pdf_path: Optional[Path],
    html_path: Path,
    md_path: Optional[Path],
    named: bool,
) -> None:
    try:
        RUNTIME_EVENTS_DIR.mkdir(parents=True, exist_ok=True)

        version = "named" if named else "anonymous"
        created_at = runtime_timestamp()
        filename = (
            "meeting_done_"
            + datetime.now().strftime("%Y%m%d_%H%M%S")
            + f"_{uuid.uuid4().hex[:6]}.json"
        )
        event_path = RUNTIME_EVENTS_DIR / filename
        tmp_path = RUNTIME_EVENTS_DIR / f".{filename}.tmp"

        payload = {
            "event": "meeting_done",
            "session_id": session_path.name,
            "session_dir": str(session_path),
            "version": version,
            "report_title": report.get("report_title", "智能会议纪要"),
            "summary_docx": str(docx_path),
            "summary_pdf": str(pdf_path) if pdf_path else "",
            "summary_html": str(html_path),
            "summary_md": str(md_path) if md_path else "",
            "created_at": created_at,
        }

        tmp_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        tmp_path.replace(event_path)
    except Exception as e:
        print(f"[Runtime Event] 写入失败：{e}")


write_idle_runtime_status_if_no_active_task()


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


# ============================================================
# 5. 初始化 ASR 与说话人分离模型
# ============================================================

print(f"[ASR] 正在加载 faster-whisper 模型：{ASR_MODEL}")
whisper_model = create_asr_model()
print(f"[ASR] faster-whisper 模型加载完成：{asr_runtime_description()}")

print(f"[Diarization] 正在加载 pyannote 模型：{DIARIZATION_MODEL}")
diarization_pipeline = Pipeline.from_pretrained(
    DIARIZATION_MODEL,
    token=HF_TOKEN,
)
diarization_device = configure_diarization_pipeline(diarization_pipeline)
print(f"[Diarization] pyannote 模型加载完成，运行设备：{diarization_device.type}")


# ============================================================
# 6. 飞书回复工具
# ============================================================

def reply_text(message_id: str, text: str) -> None:
    content = json.dumps({"text": text}, ensure_ascii=False)

    request = (
        ReplyMessageRequest.builder()
        .message_id(message_id)
        .request_body(
            ReplyMessageRequestBody.builder()
            .content(content)
            .msg_type("text")
            .build()
        )
        .build()
    )

    response = feishu_client.im.v1.message.reply(request)

    if not response.success():
        print("[Feishu] 回复失败：")
        print(response.code, response.msg, response.raw.content)


def reply_long_text(message_id: str, text: str, chunk_size: int = 3500) -> None:
    text = text.strip()
    if not text:
        reply_text(message_id, "处理完成，但没有生成有效文本。")
        return

    chunks = [text[i:i + chunk_size] for i in range(0, len(text), chunk_size)]

    for idx, chunk in enumerate(chunks, start=1):
        prefix = ""
        if len(chunks) > 1:
            prefix = f"【第 {idx}/{len(chunks)} 段】\n"
        reply_text(message_id, prefix + chunk)
        time.sleep(0.5)


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
# 7. 飞书资源下载与上传
# ============================================================

def get_tenant_access_token() -> str:
    url = "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal"
    payload = {
        "app_id": FEISHU_APP_ID,
        "app_secret": FEISHU_APP_SECRET,
    }

    resp = requests.post(url, json=payload, timeout=30)
    resp.raise_for_status()
    data = resp.json()

    if data.get("code") != 0:
        raise RuntimeError(f"获取 tenant_access_token 失败：{data}")

    token = data.get("tenant_access_token")
    if not token:
        raise RuntimeError(f"tenant_access_token 为空：{data}")

    return token


def download_message_resource(
    message_id: str,
    file_key: str,
    filename: str,
    resource_type: str = "file",
) -> Path:
    token = get_tenant_access_token()

    safe_filename = (
        filename.replace("/", "_")
        .replace("\\", "_")
        .replace(" ", "_")
    )

    save_path = DOWNLOAD_DIR / f"{int(time.time())}_{safe_filename}"

    url = (
        f"https://open.feishu.cn/open-apis/im/v1/messages/"
        f"{message_id}/resources/{file_key}"
    )

    headers = {
        "Authorization": f"Bearer {token}",
    }

    params = {"type": resource_type or "file"}

    resp = requests.get(
        url,
        headers=headers,
        params=params,
        timeout=600,
    )
    resp.raise_for_status()

    with open(save_path, "wb") as f:
        f.write(resp.content)

    return save_path


def get_message_detail(message_id: str) -> Optional[Dict]:
    token = get_tenant_access_token()
    url = f"https://open.feishu.cn/open-apis/im/v1/messages/{message_id}"
    headers = {"Authorization": f"Bearer {token}"}

    resp = requests.get(url, headers=headers, timeout=30)
    resp.raise_for_status()
    payload = resp.json()

    if payload.get("code") != 0:
        print(f"[Feishu] 获取消息详情失败：{payload}")
        return None

    data = payload.get("data", {})
    return data.get("items", [{}])[0] if data.get("items") else data.get("message")


def extract_referenced_message_id(content: Dict, message_obj=None) -> str:
    candidates = []
    for key in [
        "parent_id",
        "root_id",
        "quote_message_id",
        "reply_in_thread_message_id",
        "thread_id",
    ]:
        value = content.get(key)
        if isinstance(value, str) and value.startswith("om_"):
            candidates.append(value)

    mentions = content.get("mentions")
    if isinstance(mentions, list):
        for mention in mentions:
            if isinstance(mention, dict):
                value = mention.get("id") or mention.get("message_id")
                if isinstance(value, str) and value.startswith("om_"):
                    candidates.append(value)

    if message_obj is not None:
        for attr in ["parent_id", "root_id", "thread_id"]:
            value = getattr(message_obj, attr, "")
            if isinstance(value, str) and value.startswith("om_"):
                candidates.append(value)

    return candidates[0] if candidates else ""


def get_referenced_message_payload(content: Dict, message_obj=None) -> Optional[Dict]:
    referenced_id = extract_referenced_message_id(content, message_obj)
    if not referenced_id:
        return None

    item = get_message_detail(referenced_id)
    if not item:
        return None

    body = item.get("body", {})
    raw_content = body.get("content") or item.get("content") or "{}"
    try:
        parsed_content = json.loads(raw_content) if isinstance(raw_content, str) else raw_content
    except Exception:
        parsed_content = {"text": str(raw_content)}

    return {
        "message_id": item.get("message_id", referenced_id),
        "message_type": item.get("msg_type") or item.get("message_type") or "",
        "content": parsed_content if isinstance(parsed_content, dict) else {"text": str(parsed_content)},
    }


def upload_file_to_feishu(file_path: Path) -> str:
    token = get_tenant_access_token()
    url = "https://open.feishu.cn/open-apis/im/v1/files"

    headers = {
        "Authorization": f"Bearer {token}",
    }

    with open(file_path, "rb") as f:
        files = {
            "file": (file_path.name, f),
        }
        data = {
            "file_type": "stream",
            "file_name": file_path.name,
        }

        resp = requests.post(
            url,
            headers=headers,
            data=data,
            files=files,
            timeout=600,
        )

    resp.raise_for_status()
    payload = resp.json()

    if payload.get("code") != 0:
        raise RuntimeError(f"飞书文件上传失败：{payload}")

    file_key = payload.get("data", {}).get("file_key")
    if not file_key:
        raise RuntimeError(f"飞书文件上传后未返回 file_key：{payload}")

    return file_key


def reply_file(message_id: str, file_path: Path) -> None:
    file_key = upload_file_to_feishu(file_path)

    content = json.dumps(
        {"file_key": file_key},
        ensure_ascii=False,
    )

    request = (
        ReplyMessageRequest.builder()
        .message_id(message_id)
        .request_body(
            ReplyMessageRequestBody.builder()
            .content(content)
            .msg_type("file")
            .build()
        )
        .build()
    )

    response = feishu_client.im.v1.message.reply(request)

    if not response.success():
        raise RuntimeError(
            f"飞书文件消息回复失败："
            f"{response.code} {response.msg} {response.raw.content}"
        )


# ============================================================
# 9. 音频预处理：统一转换为 16kHz 单声道 WAV
# ============================================================

def convert_audio_to_wav_16k_mono(
    input_audio: Path,
    session_path: Path,
) -> Path:
    output_wav = session_path / "analysis_audio_16k_mono.wav"

    cmd = [
        FFMPEG_BIN,
        "-y",
        "-i",
        str(input_audio),
        "-ac",
        "1",
        "-ar",
        "16000",
        "-vn",
        str(output_wav),
    ]

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=1800,
    )

    if result.returncode != 0:
        raise RuntimeError(
            "FFmpeg 音频转换失败。\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )

    if not output_wav.exists():
        raise RuntimeError("FFmpeg 未生成转换后的 WAV 文件")

    return output_wav


def load_waveform_for_pyannote(wav_path: Path) -> Dict:
    waveform_np, sample_rate = sf.read(str(wav_path), dtype="float32")

    if waveform_np.ndim == 1:
        waveform_np = waveform_np[None, :]
    else:
        waveform_np = waveform_np.T

    waveform = torch.from_numpy(waveform_np)

    return {
        "waveform": waveform,
        "sample_rate": sample_rate,
    }


# ============================================================
# 10. 说话人分离与转写
# ============================================================

def diarize_audio(audio_path: Path, session_path: Path) -> List[Dict]:
    print(f"[Diarization] 开始说话人分离：{audio_path.name}")

    audio_for_pyannote = load_waveform_for_pyannote(audio_path)
    progress_state = {"step": "", "percent": -1, "updated_at": 0.0}
    step_labels = {
        "segmentation": "检测语音活动",
        "speaker_counting": "估算说话人数",
        "embeddings": "提取说话人特征",
        "discrete_diarization": "整理说话人时间段",
    }

    def progress_hook(
        step_name: str,
        _artifact=None,
        completed: Optional[int] = None,
        total: Optional[int] = None,
        **_kwargs,
    ) -> None:
        if completed is None or total is None or total <= 0:
            return

        percent = min(100, max(0, int(completed * 100 / total)))
        now = time.monotonic()
        same_step = progress_state["step"] == step_name
        if (
            same_step
            and percent < progress_state["percent"] + 5
            and now < progress_state["updated_at"] + 15
        ):
            return

        progress_state.update(
            {"step": step_name, "percent": percent, "updated_at": now}
        )
        label = step_labels.get(step_name, step_name)
        message = f"正在进行说话人分离：{label} {percent}%"
        print(f"[Diarization] {label} {percent}%")
        write_session_runtime_status(
            task_status="processing",
            stage="diarization",
            message=message,
            session_path=session_path,
        )

    if not DIARIZATION_LOCK.acquire(blocking=False):
        write_session_runtime_status(
            task_status="processing",
            stage="diarization",
            message="已有录音正在进行说话人分离，当前任务正在排队",
            session_path=session_path,
        )
        DIARIZATION_LOCK.acquire()

    try:
        def on_device_fallback(_error: str) -> None:
            message = "Apple GPU 不兼容当前音频处理步骤，已自动切换 CPU 继续"
            print(f"[Diarization] {message}")
            write_session_runtime_status(
                task_status="processing",
                stage="diarization",
                message=message,
                session_path=session_path,
            )

        output = run_diarization_pipeline(
            diarization_pipeline,
            audio_for_pyannote,
            hook=progress_hook,
            on_fallback=on_device_fallback,
        )
    finally:
        DIARIZATION_LOCK.release()

    diarization = getattr(
        output,
        "exclusive_speaker_diarization",
        output.speaker_diarization,
    )

    segments: List[Dict] = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append(
            {
                "start": float(turn.start),
                "end": float(turn.end),
                "speaker": str(speaker),
            }
        )

    segments.sort(key=lambda x: x["start"])

    out_path = session_path / "diarization.json"
    out_path.write_text(
        json.dumps(segments, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(f"[Diarization] 完成，共 {len(segments)} 段")
    return segments


def transcribe_audio(audio_path: Path, session_path: Path) -> List[Dict]:
    print(f"[ASR] 开始转写：{audio_path.name}")

    progress = TranscriptionProgress(
        duration=audio_duration_seconds(audio_path),
        update=lambda message: write_session_runtime_status(
            task_status="processing",
            stage="transcribing",
            message=message,
            session_path=session_path,
        ),
    )
    progress.start()
    segments, _info = transcribe_with_asr_model(whisper_model, audio_path)

    transcript_segments: List[Dict] = []
    for seg in segments:
        text = simplify_chinese(seg.text.strip())
        progress.advance(float(seg.end))
        if text:
            transcript_segments.append(
                {
                    "start": float(seg.start),
                    "end": float(seg.end),
                    "text": text,
                }
            )

    if not transcript_segments:
        raise RuntimeError("转写结果为空")

    progress.complete()
    out_path = session_path / "transcript_segments.json"
    out_path.write_text(
        json.dumps(transcript_segments, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    print(f"[ASR] 完成，共 {len(transcript_segments)} 段")
    return transcript_segments


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
    out_path.write_text(
        json.dumps(merged, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

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
    path = session_path / "speaker_map.json"
    path.write_text(
        json.dumps(speaker_map, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


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
    lines = [f"# {title}", ""]

    for seg in readable_segments:
        speaker_label = speaker_map.get(seg["speaker"], seg["speaker"])
        ts = format_timestamp(seg["start"])
        lines.append(f"[{ts}] {speaker_label}：")
        lines.append(seg["text"])
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
    path.write_text(markdown, encoding="utf-8")
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

    output_path.write_text(
        json.dumps(classification, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
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

    output_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
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


def append_requested_report_exports(message_id: str, requested_formats: set[str]) -> None:
    session_path = get_latest_session()
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
    (session_path / summary_name).write_text(summary_text, encoding="utf-8")

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
) -> None:
    session_path: Optional[Path] = None
    try:
        normalized = normalize_uploaded_transcript_text(text, title=Path(source_name).stem or "上传的转录文字材料")
        source_hash = transcript_text_sha256(text)

        if reuse_if_available:
            reusable = find_reusable_session(source_hash, "transcript_text")
            if reusable is not None:
                transcript_anon = (reusable / "transcript_anon.md").read_text(encoding="utf-8")
                speaker_map = load_speaker_map(reusable) if (reusable / "speaker_map.json").exists() else {}
                set_latest_session(reusable)
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

        session_path = create_text_session(source_name)
        write_session_metadata(
            session_path,
            {
                "source_kind": "transcript_text",
                "source_name": source_name,
                "source_sha256": source_hash,
                "created_at": runtime_timestamp(),
            },
        )
        (session_path / "uploaded_transcript.txt").write_text(text.strip(), encoding="utf-8")
        (session_path / "transcript_anon.md").write_text(normalized, encoding="utf-8")

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
) -> None:
    session_path: Optional[Path] = None
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
            reusable = find_reusable_session(audio_hash, "audio")
            if reusable is not None:
                transcript_anon = (reusable / "transcript_anon.md").read_text(encoding="utf-8")
                speaker_map = load_speaker_map(reusable)
                set_latest_session(reusable)
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

        session_path = create_session(downloaded_audio)
        session_audio = session_path / downloaded_audio.name
        write_session_metadata(
            session_path,
            {
                "source_kind": "audio",
                "source_name": file_name,
                "source_sha256": audio_hash,
                "created_at": runtime_timestamp(),
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


def regenerate_named_outputs(message_id: str, updates: Dict[str, str]) -> None:
    session_path: Optional[Path] = None
    try:
        session_path = get_latest_session()
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
        (session_path / "summary_named.txt").write_text(
            summary_named_text,
            encoding="utf-8",
        )

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

def show_current_speaker_mapping(message_id: str) -> None:
    session_path = get_latest_session()
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

def handle_text_message(message_id: str, text: str, content: Optional[Dict] = None, message_obj=None) -> None:
    text = text.strip()
    content = content or {}

    if not text:
        reply_text(message_id, "收到空文本。")
        return

    referenced_payload = get_referenced_message_payload(content, message_obj)
    if referenced_payload and (is_regenerate_report_request(text) or is_force_retranscribe(text)):
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
        show_current_speaker_mapping(message_id)
        return

    requested_exports = parse_follow_up_export_request(text)
    if requested_exports:
        append_requested_report_exports(message_id, requested_exports)
        return

    speaker_updates = parse_speaker_mapping_update(text)
    if speaker_updates:
        threading.Thread(
            target=regenerate_named_outputs,
            args=(message_id, speaker_updates),
            daemon=True,
        ).start()
        return

    if looks_like_transcript_text(text):
        threading.Thread(
            target=process_text_transcript_material,
            args=(message_id, text, "pasted_transcript.txt", True),
            daemon=True,
        ).start()
        return

    reply_text(
        message_id,
        "已收到文本。你可以发送音频、上传 txt/md/srt/vtt/csv 转录材料，或引用已上传音频并回复“重新生成会议纪要”。",
    )


# ============================================================
# 25. 飞书事件入口
# ============================================================

def on_message_receive(data: P2ImMessageReceiveV1) -> None:
    try:
        message = data.event.message
        message_id = message.message_id
        message_type = message.message_type

        if message_id in PROCESSED_MESSAGE_IDS:
            print(f"[Dedup] 跳过重复消息：{message_id}")
            return

        PROCESSED_MESSAGE_IDS.add(message_id)

        raw_content = message.content or "{}"
        content = json.loads(raw_content)

        print(f"[Feishu] 收到消息：type={message_type}, id={message_id}")
        print(f"[Feishu] content={content}")

        if message_type == "text":
            text = content.get("text", "")
            threading.Thread(
                target=handle_text_message,
                args=(message_id, text, content, message),
                daemon=True,
            ).start()

        elif message_type in {"audio", "file"}:
            threading.Thread(
                target=process_audio_message,
                args=(message_id, message_type, content),
                daemon=True,
            ).start()

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
    write_idle_runtime_status_if_no_active_task()
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
