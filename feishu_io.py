import json
import threading
import time
from pathlib import Path
from typing import Any, Dict, Optional
from urllib.parse import quote

import requests
from lark_oapi.api.im.v1 import ReplyMessageRequest, ReplyMessageRequestBody


class FeishuIO:
    def __init__(
        self,
        app_id: str,
        app_secret: str,
        download_dir: Path,
        download_max_mb: int,
        client: Any,
        http: Any = requests,
        sleep=time.sleep,
        clock=time.time,
    ) -> None:
        self.app_id = app_id
        self.app_secret = app_secret
        self.download_dir = Path(download_dir)
        self.download_max_mb = download_max_mb
        self.client = client
        self.http = http
        self.sleep = sleep
        self.clock = clock
        self._tenant_token = ""
        self._tenant_token_expires_at = 0.0
        self._tenant_token_lock = threading.Lock()

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
        self.download_dir.mkdir(parents=True, exist_ok=True)
        safe_filename = filename.replace("/", "_").replace("\\", "_").replace(" ", "_")
        safe_filename = safe_filename.strip("._") or "download"
        save_path = self.download_dir / f"{int(self.clock())}_{safe_filename}"
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
            raise RuntimeError(f"文件超过允许大小（上限 {self.download_max_mb} MB）")
        received = 0
        try:
            with save_path.open("wb") as handle:
                for chunk in response.iter_content(chunk_size=1024 * 1024):
                    if not chunk:
                        continue
                    received += len(chunk)
                    if received > max_bytes:
                        raise RuntimeError(
                            f"文件超过允许大小（上限 {self.download_max_mb} MB）"
                        )
                    handle.write(chunk)
        except Exception:
            save_path.unlink(missing_ok=True)
            raise
        return save_path

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
    ) -> Optional[Dict]:
        referenced_id = self.extract_referenced_message_id(content, message_obj)
        if not referenced_id:
            return None
        item = self.get_message_detail(referenced_id)
        if not item:
            return None
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
