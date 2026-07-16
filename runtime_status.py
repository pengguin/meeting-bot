import fcntl
import json
import uuid
from datetime import datetime
from pathlib import Path
from typing import Dict, Optional


def runtime_timestamp() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


class RuntimeStatusWriter:
    def __init__(
        self,
        runtime_dir: Path,
        status_file: Path,
        events_dir: Path,
        source: str,
    ) -> None:
        self.runtime_dir = Path(runtime_dir)
        self.status_file = Path(status_file)
        self.events_dir = Path(events_dir)
        self.source = source

    @staticmethod
    def session_fields(session_path: Optional[Path]) -> Dict[str, str]:
        if session_path is None:
            return {"session_id": "", "session_dir": ""}
        return {
            "session_id": session_path.name,
            "session_dir": str(session_path),
        }

    def write_status(
        self,
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
            self.runtime_dir.mkdir(parents=True, exist_ok=True)
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
                "source": self.source,
            }
            tmp_path = self.runtime_dir / f".status_{uuid.uuid4().hex}.json.tmp"
            tmp_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            tmp_path.replace(self.status_file)
        except Exception as exc:
            print(f"[Runtime Status] 写入失败：{exc}")

    def write_session_status(
        self,
        task_status: str,
        stage: str,
        message: str,
        session_path: Optional[Path],
        latest_pdf: Optional[Path] = None,
        latest_docx: Optional[Path] = None,
        latest_html: Optional[Path] = None,
        latest_md: Optional[Path] = None,
    ) -> None:
        fields = self.session_fields(session_path)
        self.write_status(
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

    def local_meeting_task_is_alive(self) -> bool:
        lock_path = self.runtime_dir / "local_meeting.lock"
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

    def write_idle_if_no_active_task(self) -> None:
        try:
            if self.status_file.exists():
                current = json.loads(self.status_file.read_text(encoding="utf-8"))
                if (
                    current.get("task_status") == "processing"
                    and self.local_meeting_task_is_alive()
                ):
                    return
        except (OSError, json.JSONDecodeError):
            pass
        self.write_status(
            task_status="idle",
            stage="idle",
            message="机器人后台服务运行中",
        )

    def write_meeting_done_event(
        self,
        session_path: Path,
        report: Dict,
        docx_path: Path,
        pdf_path: Optional[Path],
        html_path: Path,
        md_path: Optional[Path],
        named: bool,
    ) -> None:
        try:
            self.events_dir.mkdir(parents=True, exist_ok=True)
            version = "named" if named else "anonymous"
            filename = (
                "meeting_done_"
                + datetime.now().strftime("%Y%m%d_%H%M%S")
                + f"_{uuid.uuid4().hex[:6]}.json"
            )
            event_path = self.events_dir / filename
            tmp_path = self.events_dir / f".{filename}.tmp"
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
                "created_at": runtime_timestamp(),
            }
            tmp_path.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
            tmp_path.replace(event_path)
        except Exception as exc:
            print(f"[Runtime Event] 写入失败：{exc}")
