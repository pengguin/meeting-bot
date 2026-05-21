import hashlib
import json
import re
import shutil
import uuid
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional

from meetingbot_config import BASE_DIR, SESSION_DIR


LATEST_SESSION_FILE = BASE_DIR / "latest_session.txt"


def create_session(audio_path: Path) -> Path:
    session_id = datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:6]
    session_path = SESSION_DIR / session_id
    session_path.mkdir(parents=True, exist_ok=True)

    target_audio = session_path / audio_path.name
    shutil.copy2(audio_path, target_audio)

    LATEST_SESSION_FILE.write_text(str(session_path), encoding="utf-8")
    return session_path


def create_text_session(source_name: str = "transcript.txt") -> Path:
    safe_name = re.sub(r"[^0-9A-Za-z._\-\u4e00-\u9fa5]+", "_", source_name).strip("_") or "transcript.txt"
    session_id = datetime.now().strftime("%Y%m%d_%H%M%S") + "_" + uuid.uuid4().hex[:6]
    session_path = SESSION_DIR / session_id
    session_path.mkdir(parents=True, exist_ok=True)
    LATEST_SESSION_FILE.write_text(str(session_path), encoding="utf-8")
    (session_path / "source_name.txt").write_text(safe_name, encoding="utf-8")
    return session_path


def set_latest_session(session_path: Path) -> None:
    LATEST_SESSION_FILE.write_text(str(session_path), encoding="utf-8")


def get_latest_session() -> Optional[Path]:
    if not LATEST_SESSION_FILE.exists():
        return None

    raw = LATEST_SESSION_FILE.read_text(encoding="utf-8").strip()
    if not raw:
        return None

    path = Path(raw)
    if not path.exists():
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
    path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2), encoding="utf-8")


def load_session_metadata(session_path: Path) -> Dict:
    path = session_path / "source_metadata.json"
    if not path.exists():
        return {}

    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


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
) -> Optional[Path]:
    if not source_sha256:
        return None
    if not session_dir.exists():
        return None

    for session_path in sorted(session_dir.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
        if not session_path.is_dir():
            continue
        if not session_has_transcript(session_path):
            continue

        metadata = load_session_metadata(session_path)
        if (
            metadata.get("source_kind") == source_kind
            and metadata.get("source_sha256") == source_sha256
        ):
            return session_path

        if source_kind == "audio" and not metadata and legacy_audio_source_matches(session_path, source_sha256):
            return session_path
        if source_kind == "transcript_text" and not metadata and legacy_text_source_matches(session_path, source_sha256):
            return session_path

    return None


def read_text_file(path: Path) -> str:
    raw = path.read_bytes()
    for encoding in ["utf-8-sig", "utf-8", "gb18030", "big5"]:
        try:
            return raw.decode(encoding).strip()
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", errors="ignore").strip()


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
