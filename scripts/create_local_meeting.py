#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

# Keep local meeting generation independent from pyannote's network telemetry.
os.environ.setdefault("PYANNOTE_METRICS_ENABLED", "false")
os.environ.setdefault("OTEL_SDK_DISABLED", "true")

from chinese_text import simplify_chinese
from asr_runtime import asr_runtime_description, create_asr_model, transcribe_with_asr_model
from diarization_runtime import configure_diarization_pipeline, run_diarization_pipeline
from meetingbot_config import (
    ASR_LANGUAGE,
    ASR_MODEL,
    DIARIZATION_MODEL,
    FFMPEG_BIN,
    HF_TOKEN,
    RUNTIME_DIR,
    RUNTIME_EVENTS_DIR,
    RUNTIME_STATUS_FILE,
    get_allowed_templates,
)
from report_export import (
    convert_docx_to_pdf,
    generate_formal_minutes_docx,
    generate_formal_minutes_html,
    generate_formal_minutes_markdown,
)
from report_generation import classify_meeting_type, generate_structured_report
from session_store import (
    create_session,
    create_text_session,
    read_text_file,
    write_session_metadata,
)
from speaker_naming import build_anonymous_speaker_map
from transcript_material import (
    create_text_segments_from_transcript,
    normalize_uploaded_transcript_text,
)
from transcription_progress import TranscriptionProgress, audio_duration_seconds


def acquire_local_meeting_lock():
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    lock_handle = (RUNTIME_DIR / "local_meeting.lock").open("a+", encoding="utf-8")
    try:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock_handle.close()
        raise RuntimeError("已有本地会议正在处理，请等待完成后再添加新的会议")

    lock_handle.seek(0)
    lock_handle.truncate()
    lock_handle.write(str(os.getpid()))
    lock_handle.flush()
    return lock_handle


def runtime_timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def emit_progress(stage: str, message: str, session_path: Optional[Path] = None) -> None:
    try:
        print(
            json.dumps(
                {
                    "progress": {
                        "stage": stage,
                        "message": message,
                        "session_id": session_path.name if session_path else "",
                        "session_dir": str(session_path) if session_path else "",
                    }
                },
                ensure_ascii=False,
            ),
            flush=True,
        )
    except OSError:
        # 中止后 stdout 管道可能已被宿主 App 关闭。
        pass


def write_runtime_status(
    task_status: str,
    stage: str,
    message: str,
    session_path: Optional[Path] = None,
    latest_pdf: Optional[Path] = None,
    latest_docx: Optional[Path] = None,
    latest_html: Optional[Path] = None,
    latest_md: Optional[Path] = None,
) -> None:
    RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "service_status": "running",
        "task_status": task_status,
        "stage": stage,
        "message": message,
        "session_id": session_path.name if session_path else "",
        "session_dir": str(session_path) if session_path else "",
        "latest_pdf": str(latest_pdf) if latest_pdf else "",
        "latest_docx": str(latest_docx) if latest_docx else "",
        "latest_html": str(latest_html) if latest_html else "",
        "latest_md": str(latest_md) if latest_md else "",
        "updated_at": runtime_timestamp(),
        "source": "local_meeting",
    }
    tmp_path = RUNTIME_DIR / f".status_{uuid.uuid4().hex}.json.tmp"
    tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp_path.replace(RUNTIME_STATUS_FILE)
    if session_path is not None:
        state_path = session_path / "local_meeting_state.json"
        state_tmp = session_path / f".local_meeting_state_{uuid.uuid4().hex}.tmp"
        state_tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        state_tmp.replace(state_path)
    emit_progress(stage, message, session_path)


def write_local_meeting_request(
    session_path: Path,
    title: str,
    template: str,
    formats: set[str],
) -> None:
    payload = {
        "title": title.strip(),
        "template": template,
        "formats": sorted(formats),
        "updated_at": runtime_timestamp(),
    }
    (session_path / "local_meeting_request.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def write_meeting_done_event(
    session_path: Path,
    report: Dict,
    docx_path: Optional[Path],
    pdf_path: Optional[Path],
    html_path: Optional[Path],
    md_path: Optional[Path],
) -> None:
    RUNTIME_EVENTS_DIR.mkdir(parents=True, exist_ok=True)
    filename = (
        "meeting_done_"
        + datetime.now().strftime("%Y%m%d_%H%M%S")
        + f"_{uuid.uuid4().hex[:6]}.json"
    )
    payload = {
        "event": "meeting_done",
        "session_id": session_path.name,
        "session_dir": str(session_path),
        "version": "anonymous",
        "report_title": report.get("report_title", "智能会议纪要"),
        "summary_docx": str(docx_path) if docx_path else "",
        "summary_pdf": str(pdf_path) if pdf_path else "",
        "summary_html": str(html_path) if html_path else "",
        "summary_md": str(md_path) if md_path else "",
        "created_at": runtime_timestamp(),
    }
    event_path = RUNTIME_EVENTS_DIR / filename
    tmp_path = RUNTIME_EVENTS_DIR / f".{filename}.tmp"
    tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp_path.replace(event_path)


def convert_audio_to_wav_16k_mono(input_audio: Path, session_path: Path) -> Path:
    output_wav = session_path / "analysis_audio_16k_mono.wav"
    result = subprocess.run(
        [
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
        ],
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
    import soundfile as sf
    import torch

    waveform_np, sample_rate = sf.read(str(wav_path), dtype="float32")
    if waveform_np.ndim == 1:
        waveform_np = waveform_np[None, :]
    else:
        waveform_np = waveform_np.T
    return {
        "waveform": torch.from_numpy(waveform_np),
        "sample_rate": sample_rate,
    }


def diarize_audio(
    audio_path: Path,
    session_path: Path,
    diarization_pipeline,
) -> List[Dict]:
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
        emit_progress("diarization", message)
        write_runtime_status(
            "processing",
            "diarization",
            message,
            session_path,
        )

    def on_device_fallback(_error: str) -> None:
        message = "Apple GPU 不兼容当前音频处理步骤，已自动切换 CPU 继续"
        emit_progress("diarization", message)
        write_runtime_status("processing", "diarization", message, session_path)

    output = run_diarization_pipeline(
        diarization_pipeline,
        load_waveform_for_pyannote(audio_path),
        hook=progress_hook,
        on_fallback=on_device_fallback,
    )
    diarization = getattr(output, "exclusive_speaker_diarization", output.speaker_diarization)
    segments: List[Dict] = []
    for turn, _, speaker in diarization.itertracks(yield_label=True):
        segments.append(
            {
                "start": float(turn.start),
                "end": float(turn.end),
                "speaker": str(speaker),
            }
        )
    segments.sort(key=lambda item: item["start"])
    (session_path / "diarization.json").write_text(
        json.dumps(segments, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return segments


def transcribe_audio(
    audio_path: Path,
    session_path: Path,
    whisper_model,
) -> List[Dict]:
    progress = TranscriptionProgress(
        duration=audio_duration_seconds(audio_path),
        update=lambda message: write_runtime_status(
            "processing",
            "transcribing",
            message,
            session_path,
        ),
    )
    progress.start()
    segments, _info = transcribe_with_asr_model(whisper_model, audio_path)
    transcript_segments: List[Dict] = []
    for segment in segments:
        text = simplify_chinese(segment.text.strip())
        progress.advance(float(segment.end))
        if text:
            transcript_segments.append(
                {
                    "start": float(segment.start),
                    "end": float(segment.end),
                    "text": text,
                }
            )
    if not transcript_segments:
        raise RuntimeError("转写结果为空")
    progress.complete()
    (session_path / "transcript_segments.json").write_text(
        json.dumps(transcript_segments, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return transcript_segments


def overlap_duration(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def assign_speakers_to_transcript(
    transcript_segments: List[Dict],
    diarization_segments: List[Dict],
    session_path: Path,
) -> List[Dict]:
    merged: List[Dict] = []
    for transcript in transcript_segments:
        best_speaker = "UNKNOWN"
        best_overlap = 0.0
        for diarization in diarization_segments:
            overlap = overlap_duration(
                transcript["start"],
                transcript["end"],
                diarization["start"],
                diarization["end"],
            )
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = diarization["speaker"]
        merged.append(
            {
                "start": transcript["start"],
                "end": transcript["end"],
                "speaker": best_speaker,
                "text": transcript["text"],
            }
        )
    (session_path / "transcript_with_speaker_raw.json").write_text(
        json.dumps(merged, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return merged


def build_default_speaker_map(merged_segments: List[Dict], session_path: Path) -> Dict[str, str]:
    speaker_map = build_anonymous_speaker_map(
        segment["speaker"] for segment in merged_segments
    )
    (session_path / "speaker_map.json").write_text(
        json.dumps(speaker_map, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return speaker_map


def format_timestamp(seconds: float) -> str:
    total = max(0, int(seconds))
    hours = total // 3600
    minutes = (total % 3600) // 60
    secs = total % 60
    return f"{hours:02d}:{minutes:02d}:{secs:02d}" if hours > 0 else f"{minutes:02d}:{secs:02d}"


def merge_adjacent_same_speaker(segments: List[Dict], gap_threshold: float = 1.2) -> List[Dict]:
    if not segments:
        return []
    merged = [segments[0].copy()]
    for segment in segments[1:]:
        previous = merged[-1]
        if previous["speaker"] == segment["speaker"] and segment["start"] - previous["end"] <= gap_threshold:
            previous["end"] = segment["end"]
            previous["text"] = previous["text"].rstrip() + " " + segment["text"].lstrip()
        else:
            merged.append(segment.copy())
    return merged


def render_transcript_markdown(
    merged_segments: List[Dict],
    speaker_map: Dict[str, str],
    title: str,
) -> str:
    lines = [f"# {title}", ""]
    for segment in merge_adjacent_same_speaker(merged_segments):
        lines.append(
            f"[{format_timestamp(segment['start'])}] "
            f"{speaker_map.get(segment['speaker'], segment['speaker'])}："
        )
        lines.append(segment["text"])
        lines.append("")
    return "\n".join(lines).strip()


def create_session_from_transcript(
    title: str,
    transcript_path: Path,
    audio_path: Optional[Path],
    template: str,
    formats: set[str],
) -> tuple[Path, str, Dict[str, str]]:
    transcript_text = read_text_file(transcript_path)
    if audio_path is not None:
        session_path = create_session(audio_path)
    else:
        session_path = create_text_session(transcript_path.name)

    write_session_metadata(
        session_path,
        {
            "source_kind": "local_transcript",
            "source_name": transcript_path.name,
            "audio_name": audio_path.name if audio_path else "",
            "created_at": runtime_timestamp(),
        },
    )
    write_local_meeting_request(session_path, title, template, formats)
    write_runtime_status("processing", "importing_transcript", "正在导入转录稿", session_path)
    shutil.copy2(transcript_path, session_path / transcript_path.name)
    (session_path / "uploaded_transcript.txt").write_text(transcript_text.strip(), encoding="utf-8")
    transcript_markdown = normalize_uploaded_transcript_text(
        transcript_text,
        title=title or transcript_path.stem or "上传的转录文字材料",
    )
    (session_path / "transcript_anon.md").write_text(transcript_markdown, encoding="utf-8")
    merged_segments = create_text_segments_from_transcript(transcript_text, session_path)
    speakers: List[str] = []
    for segment in merged_segments:
        speaker = segment.get("speaker", "TEXT")
        if speaker not in speakers:
            speakers.append(speaker)
    speaker_map = {"TEXT": "转录文本"} if speakers == ["TEXT"] else {speaker: speaker for speaker in speakers}
    (session_path / "speaker_map.json").write_text(
        json.dumps(speaker_map, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return session_path, transcript_markdown, speaker_map


def create_session_from_audio(
    title: str,
    audio_path: Path,
    template: str,
    formats: set[str],
) -> tuple[Path, str, Dict[str, str]]:
    from pyannote.audio import Pipeline

    session_path = create_session(audio_path)
    write_session_metadata(
        session_path,
        {
            "source_kind": "local_audio",
            "source_name": audio_path.name,
            "created_at": runtime_timestamp(),
        },
    )
    write_local_meeting_request(session_path, title, template, formats)
    session_audio = session_path / audio_path.name
    write_runtime_status("processing", "converting_audio", "正在转换音频", session_path)
    analysis_audio = convert_audio_to_wav_16k_mono(session_audio, session_path)

    write_runtime_status("processing", "loading_models", "正在加载转写模型", session_path)
    whisper_model = create_asr_model()
    emit_progress("loading_models", f"转写模型已启用加速：{asr_runtime_description()}", session_path)
    diarization_pipeline = Pipeline.from_pretrained(DIARIZATION_MODEL, token=HF_TOKEN)
    diarization_device = configure_diarization_pipeline(diarization_pipeline)
    emit_progress("loading_models", f"说话人分离模型使用 {diarization_device.type.upper()} 运行", session_path)

    write_runtime_status("processing", "diarization", "正在进行说话人分离", session_path)
    diarization_segments = diarize_audio(analysis_audio, session_path, diarization_pipeline)
    write_runtime_status("processing", "transcribing", "正在语音转写", session_path)
    transcript_segments = transcribe_audio(analysis_audio, session_path, whisper_model)
    write_runtime_status("processing", "aligning_speakers", "正在对齐说话人与转录文本", session_path)
    merged_segments = assign_speakers_to_transcript(transcript_segments, diarization_segments, session_path)
    speaker_map = build_default_speaker_map(merged_segments, session_path)
    transcript_markdown = render_transcript_markdown(
        merged_segments,
        speaker_map,
        "完整转录稿（匿名说话人版）",
    )
    (session_path / "transcript_anon.md").write_text(transcript_markdown, encoding="utf-8")
    return session_path, transcript_markdown, speaker_map


def generate_outputs(
    title: str,
    transcript_markdown: str,
    speaker_map: Dict[str, str],
    session_path: Path,
    template: str,
    formats: set[str],
) -> Dict:
    if template == "auto":
        write_runtime_status("processing", "classifying_meeting", "正在识别会议类型", session_path)
        classification = classify_meeting_type(transcript_markdown, session_path)
    else:
        if template not in get_allowed_templates():
            raise RuntimeError(f"未知会议类型：{template}")
        classification = {
            "template": template,
            "confidence": 1.0,
            "reason": "用户在本地新增会议中手动指定模板。",
        }
        (session_path / "classification.json").write_text(
            json.dumps(classification, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    write_runtime_status("processing", "generating_report", "正在生成会议纪要", session_path)
    report = generate_structured_report(
        transcript_markdown=transcript_markdown,
        classification=classification,
        session_path=session_path,
        named=False,
    )
    if title.strip():
        report["report_title"] = title.strip()
        (session_path / "report_anon.json").write_text(
            json.dumps(report, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    write_runtime_status("processing", "generating_report_exports", "正在导出纪要文件", session_path)
    docx_path = None
    html_path = None
    md_path = None
    pdf_path = None
    if "docx" in formats or "pdf" in formats:
        docx_path = generate_formal_minutes_docx(
            report=report,
            classification=classification,
            session_path=session_path,
            named=False,
            speaker_map=speaker_map,
        )
    if "html" in formats:
        html_output = (
            docx_path.with_suffix(".html")
            if docx_path is not None
            else session_path / f"{report.get('report_title', '会议纪要')}_匿名版.html"
        )
        html_path = generate_formal_minutes_html(
            report=report,
            output_path=html_output,
            named=False,
            speaker_map=speaker_map,
        )
    if "md" in formats:
        markdown_output = (
            docx_path.with_suffix(".md")
            if docx_path is not None
            else session_path / f"{report.get('report_title', '会议纪要')}_匿名版.md"
        )
        md_path = generate_formal_minutes_markdown(
            report=report,
            output_path=markdown_output,
            named=False,
            speaker_map=speaker_map,
        )
    if "pdf" in formats:
        if docx_path is None:
            raise RuntimeError("生成 PDF 需要先生成临时 DOCX")
        pdf_path = convert_docx_to_pdf(docx_path)
    if "docx" not in formats and docx_path is not None:
        docx_path.unlink(missing_ok=True)
        docx_path = None

    write_runtime_status(
        "done",
        "done",
        "本地新增会议已生成",
        session_path,
        latest_docx=docx_path,
        latest_pdf=pdf_path,
        latest_html=html_path,
        latest_md=md_path,
    )
    write_meeting_done_event(session_path, report, docx_path, pdf_path, html_path, md_path)
    return {
        "session_id": session_path.name,
        "session_dir": str(session_path),
        "docx": str(docx_path) if docx_path else "",
        "html": str(html_path) if html_path else "",
        "md": str(md_path) if md_path else "",
        "pdf": str(pdf_path) if pdf_path else "",
    }


def become_process_group_leader() -> None:
    # 自成进程组，宿主 App 中止时可整组终止（含 ffmpeg、LLM、LibreOffice 等子进程）。
    try:
        os.setsid()
    except OSError:
        pass


def install_termination_handler() -> None:
    def handle_termination(_signum, _frame):
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, handle_termination)


def main() -> None:
    become_process_group_leader()
    install_termination_handler()

    parser = argparse.ArgumentParser()
    parser.add_argument("--title", default="")
    parser.add_argument("--audio", default="")
    parser.add_argument("--transcript", default="")
    parser.add_argument("--template", default="auto")
    parser.add_argument("--formats", default="html,docx")
    args = parser.parse_args()

    audio_path = Path(args.audio).expanduser() if args.audio else None
    transcript_path = Path(args.transcript).expanduser() if args.transcript else None
    formats = {item.strip().lower() for item in args.formats.split(",") if item.strip()}

    if transcript_path is None and audio_path is None:
        raise RuntimeError("至少需要提供录音或转录稿")
    if transcript_path is not None and not transcript_path.exists():
        raise RuntimeError("转录稿文件不存在")
    if audio_path is not None and not audio_path.exists():
        raise RuntimeError("录音文件不存在")

    lock_handle = acquire_local_meeting_lock()
    session_path: Optional[Path] = None
    try:
        if transcript_path is not None:
            write_runtime_status("processing", "importing_transcript", "正在导入转录稿")
            session_path, transcript_markdown, speaker_map = create_session_from_transcript(
                args.title,
                transcript_path,
                audio_path,
                args.template,
                formats,
            )
        else:
            assert audio_path is not None
            write_runtime_status("processing", "received_audio", "正在导入录音")
            session_path, transcript_markdown, speaker_map = create_session_from_audio(
                args.title,
                audio_path,
                args.template,
                formats,
            )
        result = generate_outputs(
            title=args.title,
            transcript_markdown=transcript_markdown,
            speaker_map=speaker_map,
            session_path=session_path,
            template=args.template,
            formats=formats,
        )
        print(json.dumps(result, ensure_ascii=False))
    except (KeyboardInterrupt, SystemExit):
        # 用户中止：清理本次创建的半成品会话目录，避免残留占用磁盘。
        if session_path is not None:
            shutil.rmtree(session_path, ignore_errors=True)
        write_runtime_status(
            "idle",
            "idle",
            "新增会议处理已中止",
        )
        raise
    except Exception as error:
        write_runtime_status(
            "error",
            "error",
            f"新增会议失败：{error}",
            session_path,
        )
        raise
    finally:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_UN)
        lock_handle.close()


if __name__ == "__main__":
    main()
