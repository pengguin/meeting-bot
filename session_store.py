import hashlib
import re
import shutil
import uuid
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional

from meetingbot_config import BASE_DIR, SESSION_DIR, TRANSCRIPT_MAX_CHARACTERS, TRANSCRIPT_MAX_MB
from durable_storage import (
    DataStoreError,
    atomic_write_text,
    read_versioned_json_object,
    write_versioned_json_object,
)


LATEST_SESSION_FILE = BASE_DIR / "latest_session.txt"
LATEST_SESSIONS_DIR = BASE_DIR / "runtime" / "latest_sessions"


def session_scope_digest(session_scope: Optional[str]) -> str:
    normalized = (session_scope or "").strip()
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest() if normalized else ""


def latest_session_file(session_scope: Optional[str] = None) -> Path:
    digest = session_scope_digest(session_scope)
    if not digest:
        return LATEST_SESSION_FILE
    return LATEST_SESSIONS_DIR / f"{digest}.txt"


def _write_latest_session_file(path: Path, session_path: Path) -> None:
    atomic_write_text(path, str(session_path))


def _is_session_directory(path: Path) -> bool:
    try:
        path.resolve().relative_to(SESSION_DIR.resolve())
    except (OSError, ValueError):
        return False
    return path.is_dir()


def create_session(audio_path: Path, session_scope: Optional[str] = None) -> Path:
    session_id = datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:6]
    session_path = SESSION_DIR / session_id
    session_path.mkdir(parents=True, exist_ok=True)

    target_audio = session_path / audio_path.name
    shutil.copy2(audio_path, target_audio)

    set_latest_session(session_path, session_scope=session_scope)
    return session_path


def create_text_session(
    source_name: str = "transcript.txt",
    session_scope: Optional[str] = None,
) -> Path:
    safe_name = re.sub(r"[^0-9A-Za-z._\-\u4e00-\u9fa5]+", "_", source_name).strip("_") or "transcript.txt"
    session_id = datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:6]
    session_path = SESSION_DIR / session_id
    session_path.mkdir(parents=True, exist_ok=True)
    set_latest_session(session_path, session_scope=session_scope)
    (session_path / "source_name.txt").write_text(safe_name, encoding="utf-8")
    return session_path


def set_latest_session(session_path: Path, session_scope: Optional[str] = None) -> None:
    if not _is_session_directory(session_path):
        raise ValueError("最近会议必须位于会议输出目录内")
    _write_latest_session_file(latest_session_file(session_scope), session_path.resolve())


def get_latest_session(session_scope: Optional[str] = None) -> Optional[Path]:
    path_file = latest_session_file(session_scope)
    if not path_file.exists():
        return None

    raw = path_file.read_text(encoding="utf-8").strip()
    if not raw:
        return None

    path = Path(raw)
    if not _is_session_directory(path):
        return None

    return path


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def text_sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_session_metadata(session_path: Path, metadata: Dict) -> None:
    path = session_path / "source_metadata.json"
    write_versioned_json_object(
        path,
        metadata,
        document_type="session_source_metadata",
    )


def load_session_metadata(session_path: Path) -> Dict:
    path = session_path / "source_metadata.json"
    return read_versioned_json_object(
        path,
        document_type="session_source_metadata",
        missing={},
    )


def canonical_transcript_source_text(text: str) -> str:
    cleaned = text.replace("\r\n", "\n").replace("\r", "\n").strip()
    lines = [line.rstrip() for line in cleaned.splitlines()]
    return "\n".join(lines).strip()


def transcript_text_sha256(text: str) -> str:
    return text_sha256(canonical_transcript_source_text(text))


def session_has_transcript(session_path: Path) -> bool:
    return (session_path / "transcript_anon.md").exists()


def legacy_audio_source_matches(session_path: Path, source_sha256: str) -> bool:
    for candidate in session_path.iterdir():
        if not candidate.is_file():
            continue
        if candidate.name == "analysis_audio_16k_mono.wav":
            continue
        if not is_audio_material_file(candidate.name):
            continue
        try:
            if file_sha256(candidate) == source_sha256:
                return True
        except Exception as error:
            print(f"[Reuse] 跳过无法校验的历史音频：{candidate} {error}")
    return False


def legacy_text_source_matches(session_path: Path, source_sha256: str) -> bool:
    candidates = [
        session_path / "uploaded_transcript.txt",
        session_path / "transcript_anon.md",
    ]
    for candidate in candidates:
        if not candidate.exists():
            continue
        try:
            if transcript_text_sha256(read_text_file(candidate)) == source_sha256:
                return True
        except Exception as error:
            print(f"[Reuse] 跳过无法校验的历史文本：{candidate} {error}")
    return False


def find_reusable_session(
    source_sha256: str,
    source_kind: str,
    session_dir: Path = SESSION_DIR,
    session_scope: Optional[str] = None,
) -> Optional[Path]:
    if not source_sha256:
        return None
    if not session_dir.exists():
        return None

    scope_digest = session_scope_digest(session_scope)
    for session_path in sorted(session_dir.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
        if not session_path.is_dir():
            continue
        if not session_has_transcript(session_path):
            continue

        try:
            metadata = load_session_metadata(session_path)
        except DataStoreError as error:
            print(f"[Reuse] 跳过元数据损坏的历史会话：{session_path} {error}")
            continue
        if scope_digest and metadata.get("session_scope_sha256") != scope_digest:
            continue
        if (
            metadata.get("source_kind") == source_kind
            and metadata.get("source_sha256") == source_sha256
        ):
            return session_path

        if scope_digest:
            continue
        if source_kind == "audio" and not metadata and legacy_audio_source_matches(session_path, source_sha256):
            return session_path
        if source_kind == "transcript_text" and not metadata and legacy_text_source_matches(session_path, source_sha256):
            return session_path

    return None


def read_text_file(
    path: Path,
    *,
    max_bytes: int = TRANSCRIPT_MAX_MB * 1024 * 1024,
    max_characters: int = TRANSCRIPT_MAX_CHARACTERS,
) -> str:
    try:
        declared_size = path.stat().st_size
    except OSError as error:
        raise RuntimeError(f"无法读取转录文字材料：{error}") from error
    if declared_size > max_bytes:
        raise RuntimeError(f"转录文字材料超过允许大小（上限 {max_bytes // 1024 // 1024} MB）")
    with path.open("rb") as handle:
        raw = handle.read(max_bytes + 1)
    if len(raw) > max_bytes:
        raise RuntimeError(f"转录文字材料超过允许大小（上限 {max_bytes // 1024 // 1024} MB）")
    for encoding in ["utf-8-sig", "utf-8", "gb18030", "big5"]:
        try:
            text = raw.decode(encoding).strip()
            break
        except UnicodeDecodeError:
            continue
    else:
        text = raw.decode("utf-8", errors="ignore").strip()
    if len(text) > max_characters:
        raise RuntimeError(f"转录文字材料字符数超过上限（{max_characters} 字符）")
    return text


def is_text_material_file(filename: str) -> bool:
    return Path(filename).suffix.lower() in {".txt", ".md", ".markdown", ".csv", ".srt", ".vtt"}


def is_audio_material_file(filename: str) -> bool:
    return Path(filename).suffix.lower() in {
        ".m4a",
        ".mp3",
        ".wav",
        ".aac",
        ".flac",
        ".ogg",
        ".opus",
        ".mp4",
        ".mov",
        ".webm",
    }
