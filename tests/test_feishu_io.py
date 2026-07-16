from pathlib import Path

import pytest

from feishu_io import FeishuIO


class FakeResponse:
    def __init__(self, payload=None, chunks=(), headers=None):
        self.payload = payload or {}
        self.chunks = chunks
        self.headers = headers or {}

    def raise_for_status(self):
        return None

    def json(self):
        return self.payload

    def iter_content(self, chunk_size):
        yield from self.chunks


class FakeHTTP:
    def __init__(self, get_responses=(), post_responses=()):
        self.get_responses = list(get_responses)
        self.post_responses = list(post_responses)
        self.get_calls = []
        self.post_calls = []

    def get(self, url, **kwargs):
        self.get_calls.append((url, kwargs))
        return self.get_responses.pop(0)

    def post(self, url, **kwargs):
        self.post_calls.append((url, kwargs))
        return self.post_responses.pop(0)


def make_io(tmp_path: Path, http: FakeHTTP, max_mb=1) -> FeishuIO:
    return FeishuIO(
        app_id="app-id",
        app_secret="secret",
        download_dir=tmp_path / "downloads",
        download_max_mb=max_mb,
        client=None,
        http=http,
        clock=lambda: 1000.0,
    )


def token_response(token="token-1"):
    return FakeResponse({"code": 0, "tenant_access_token": token, "expire": 7200})


def test_token_cache_and_referenced_message_flow(tmp_path):
    message = {
        "code": 0,
        "data": {
            "items": [
                {
                    "message_id": "om_source",
                    "msg_type": "text",
                    "body": {"content": '{"text":"会议转录"}'},
                }
            ]
        },
    }
    http = FakeHTTP(
        get_responses=[FakeResponse(message)],
        post_responses=[token_response()],
    )
    io = make_io(tmp_path, http)

    payload = io.get_referenced_message_payload({"parent_id": "om_source"})
    assert payload == {
        "message_id": "om_source",
        "message_type": "text",
        "content": {"text": "会议转录"},
    }
    assert io.get_tenant_access_token() == "token-1"
    assert len(http.post_calls) == 1


def test_download_stream_enforces_size_and_removes_partial_file(tmp_path):
    http = FakeHTTP(
        get_responses=[FakeResponse(chunks=[b"a" * 700_000, b"b" * 700_000])],
        post_responses=[token_response()],
    )
    io = make_io(tmp_path, http, max_mb=1)

    with pytest.raises(RuntimeError, match="文件超过允许大小"):
        io.download_message_resource("om_1", "file-key", "../unsafe name.m4a")

    assert not list((tmp_path / "downloads").iterdir())


def test_download_stream_returns_sanitized_path(tmp_path):
    http = FakeHTTP(
        get_responses=[FakeResponse(chunks=[b"audio"], headers={"Content-Length": "5"})],
        post_responses=[token_response()],
    )
    io = make_io(tmp_path, http)

    path = io.download_message_resource("om_1", "file-key", "meeting audio.m4a")

    assert path.name == "1000_meeting_audio.m4a"
    assert path.read_bytes() == b"audio"
