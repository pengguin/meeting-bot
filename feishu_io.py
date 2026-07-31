import json
import os
import shutil
import threading
import time
import uuid
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import quote

import requests
from lark_oapi.api.im.v1 import ReplyMessageRequest, ReplyMessageRequestBody


class ReferencedMessageAuthorizationError(PermissionError):
    """Raised when a referenced message cannot be bound to the current chat."""


class FeishuIO:
    def __init__(
        self,
        app_id: str,
        app_secret: str,
        download_dir: Path,
        download_max_mb: int,
        client: Any,
        download_total_max_mb: int = 4096,
        retention_hours: int = 24,
        http: Any = requests,
        sleep=time.sleep,
        clock=time.time,
    ) -> None:
        self.app_id = app_id
        self.app_secret = app_secret
        self.download_dir = Path(download_dir)
        self.download_max_mb = download_max_mb
        self.download_total_max_bytes = max(1, download_total_max_mb) * 1024 * 1024
        self.retention_seconds = max(1, retention_hours) * 60 * 60
        self.client = client
        self.http = http
        self.sleep = sleep
        self.clock = clock
        self._tenant_token = ""
        self._tenant_token_expires_at = 0.0
        self._tenant_token_lock = threading.Lock()
        self._download_lock = threading.Lock()

    def reply_text(self, message_id: str, text: str) -> None:
        request = (
            ReplyMessageRequest.builder()
            .message_id(message_id)
            .request_body(
                ReplyMessageRequestBody.builder()
                .content(json.dumps({"text": text}, ensure_ascii=False))
                .msg_type("text")
                .build()
            )
            .build()
        )
        response = self.client.im.v1.message.reply(request)
        if not response.success():
            print("[Feishu] 回复失败：")
            print(response.code, response.msg, response.raw.content)

    def reply_long_text(
        self,
        message_id: str,
        text: str,
        chunk_size: int = 3500,
    ) -> None:
        text = text.strip()
        if not text:
            self.reply_text(message_id, "处理完成，但没有生成有效文本。")
            return
        chunks = [text[i:i + chunk_size] for i in range(0, len(text), chunk_size)]
        for index, chunk in enumerate(chunks, start=1):
            prefix = f"【第 {index}/{len(chunks)} 段】\n" if len(chunks) > 1 else ""
            self.reply_text(message_id, prefix + chunk)
            if index < len(chunks):
                self.sleep(0.5)

    def get_tenant_access_token(self) -> str:
        with self._tenant_token_lock:
            now = self.clock()
            if self._tenant_token and now < self._tenant_token_expires_at - 60:
                return self._tenant_token
            response = self.http.post(
                "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal",
                json={"app_id": self.app_id, "app_secret": self.app_secret},
                timeout=30,
            )
            response.raise_for_status()
            data = response.json()
            if data.get("code") != 0:
                raise RuntimeError(
                    f"获取飞书访问凭据失败（code={data.get('code', 'unknown')}）"
                )
            token = data.get("tenant_access_token")
            if not token:
                raise RuntimeError("飞书访问凭据响应为空")
            try:
                expires_in = max(300, int(data.get("expire", 7200) or 7200))
            except (TypeError, ValueError):
                expires_in = 7200
            self._tenant_token = token
            self._tenant_token_expires_at = now + expires_in
            return token

    def download_message_resource(
        self,
        message_id: str,
        file_key: str,
        filename: str,
        resource_type: str = "file",
    ) -> Path:
        self.download_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        safe_filename = filename.replace("/", "_").replace("\\", "_").replace(" ", "_")
        safe_filename = safe_filename.strip("._") or "download"
        url = (
            "https://open.feishu.cn/open-apis/im/v1/messages/"
            f"{quote(message_id, safe='')}/resources/{quote(file_key, safe='')}"
        )
        response = self.http.get(
            url,
            headers={"Authorization": f"Bearer {self.get_tenant_access_token()}"},
            params={"type": resource_type or "file"},
            timeout=600,
            stream=True,
        )
        response.raise_for_status()
        max_bytes = self.download_max_mb * 1024 * 1024
        try:
            declared_size = int(response.headers.get("Content-Length", "0") or 0)
        except (TypeError, ValueError):
            declared_size = 0
        if declared_size > max_bytes:
            self._close_response(response)
            raise RuntimeError(f"文件超过允许大小（上限 {self.download_max_mb} MB）")
        with self._download_lock:
            self._cleanup_expired_downloads_locked()
            existing_bytes = self._download_bytes_locked()
            if declared_size and existing_bytes + declared_size > self.download_total_max_bytes:
                self._close_response(response)
                raise RuntimeError("临时下载目录空间不足，请稍后重试")

            task_dir = self.download_dir / f"task-{uuid.uuid4().hex}"
            task_dir.mkdir(mode=0o700)
            save_path = task_dir / safe_filename
            received = 0
            try:
                with save_path.open("xb") as handle:
                    os.chmod(save_path, 0o600)
                    for chunk in response.iter_content(chunk_size=1024 * 1024):
                        if not chunk:
                            continue
                        received += len(chunk)
                        if received > max_bytes:
                            raise RuntimeError(
                                f"文件超过允许大小（上限 {self.download_max_mb} MB）"
                            )
                        if existing_bytes + received > self.download_total_max_bytes:
                            raise RuntimeError("临时下载目录空间不足，请稍后重试")
                        handle.write(chunk)
            except Exception:
                shutil.rmtree(task_dir, ignore_errors=True)
                raise
            finally:
                self._close_response(response)
            return save_path

    def cleanup_download(self, downloaded_path: Optional[Path]) -> None:
        if downloaded_path is None:
            return
        try:
            task_dir = Path(downloaded_path).resolve().parent
            task_dir.relative_to(self.download_dir.resolve())
        except (OSError, ValueError):
            return
        if task_dir == self.download_dir.resolve() or not task_dir.name.startswith("task-"):
            return
        with self._download_lock:
            shutil.rmtree(task_dir, ignore_errors=True)

    def cleanup_expired_downloads(self) -> None:
        with self._download_lock:
            self._cleanup_expired_downloads_locked()

    def _cleanup_expired_downloads_locked(self) -> None:
        cutoff = self.clock() - self.retention_seconds
        if not self.download_dir.exists():
            return
        for path in self.download_dir.iterdir():
            try:
                modified_at = path.stat().st_mtime
            except OSError:
                continue
            if modified_at >= cutoff:
                continue
            if path.is_dir() and path.name.startswith("task-"):
                shutil.rmtree(path, ignore_errors=True)
            elif path.is_file():
                path.unlink(missing_ok=True)

    def _download_bytes_locked(self) -> int:
        total = 0
        if not self.download_dir.exists():
            return total
        for path in self.download_dir.rglob("*"):
            try:
                if path.is_file():
                    total += path.stat().st_size
            except OSError:
                continue
        return total

    @staticmethod
    def _close_response(response: Any) -> None:
        close = getattr(response, "close", None)
        if callable(close):
            close()

    def get_message_detail(self, message_id: str) -> Optional[Dict]:
        response = self.http.get(
            "https://open.feishu.cn/open-apis/im/v1/messages/"
            + quote(message_id, safe=""),
            headers={"Authorization": f"Bearer {self.get_tenant_access_token()}"},
            timeout=30,
        )
        response.raise_for_status()
        payload = response.json()
        if payload.get("code") != 0:
            print(f"[Feishu] 获取消息详情失败：{payload}")
            return None
        data = payload.get("data", {})
        return data.get("items", [{}])[0] if data.get("items") else data.get("message")

    @staticmethod
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

    def get_referenced_message_payload(
        self,
        content: Dict,
        message_obj=None,
        *,
        expected_chat_id: str,
    ) -> Optional[Dict]:
        referenced_id = self.extract_referenced_message_id(content, message_obj)
        if not referenced_id:
            return None
        expected_chat_id = str(expected_chat_id or "").strip()
        if not expected_chat_id:
            print(
                "[Security] 拒绝读取引用消息："
                f"message_id={referenced_id}, reason=missing_current_chat"
            )
            raise ReferencedMessageAuthorizationError(
                "无法验证引用消息是否属于当前会话"
            )
        item = self.get_message_detail(referenced_id)
        if not item:
            return None
        referenced_chat_id = str(item.get("chat_id") or "").strip()
        if not referenced_chat_id:
            print(
                "[Security] 拒绝读取引用消息："
                f"message_id={referenced_id}, reason=missing_referenced_chat"
            )
            raise ReferencedMessageAuthorizationError(
                "无法验证引用消息是否属于当前会话"
            )
        if referenced_chat_id != expected_chat_id:
            print(
                "[Security] 拒绝读取引用消息："
                f"message_id={referenced_id}, reason=chat_mismatch"
            )
            raise ReferencedMessageAuthorizationError(
                "引用消息不属于当前会话"
            )
        body = item.get("body", {})
        raw_content = body.get("content") or item.get("content") or "{}"
        try:
            parsed = json.loads(raw_content) if isinstance(raw_content, str) else raw_content
        except (TypeError, ValueError, json.JSONDecodeError):
            parsed = {"text": str(raw_content)}
        return {
            "message_id": item.get("message_id", referenced_id),
            "message_type": item.get("msg_type") or item.get("message_type") or "",
            "content": parsed if isinstance(parsed, dict) else {"text": str(parsed)},
        }

    def upload_file(self, file_path: Path) -> str:
        with Path(file_path).open("rb") as handle:
            response = self.http.post(
                "https://open.feishu.cn/open-apis/im/v1/files",
                headers={"Authorization": f"Bearer {self.get_tenant_access_token()}"},
                data={"file_type": "stream", "file_name": file_path.name},
                files={"file": (file_path.name, handle)},
                timeout=600,
            )
        response.raise_for_status()
        payload = response.json()
        if payload.get("code") != 0:
            raise RuntimeError(f"飞书文件上传失败：{payload}")
        file_key = payload.get("data", {}).get("file_key")
        if not file_key:
            raise RuntimeError(f"飞书文件上传后未返回 file_key：{payload}")
        return file_key

    def reply_file(self, message_id: str, file_path: Path) -> None:
        request = (
            ReplyMessageRequest.builder()
            .message_id(message_id)
            .request_body(
                ReplyMessageRequestBody.builder()
                .content(json.dumps({"file_key": self.upload_file(file_path)}))
                .msg_type("file")
                .build()
            )
            .build()
        )
        response = self.client.im.v1.message.reply(request)
        if not response.success():
            raise RuntimeError(
                "飞书文件消息回复失败："
                f"{response.code} {response.msg} {response.raw.content}"
            )
