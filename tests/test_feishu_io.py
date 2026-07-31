from pathlib import Path

import pytest

from feishu_io import FeishuIO, ReferencedMessageAuthorizationError


class FakeResponse:
    def __init__(self, payload=None, chunks=(), headers=None):
        self.payload = payload or {}
        self.chunks = chunks
        self.headers = headers or {}
        self.closed = False

    def raise_for_status(self):
        return None

    def json(self):
        return self.payload

    def iter_content(self, chunk_size):
        yield from self.chunks

    def close(self):
        self.closed = True


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


def make_io(tmp_path: Path, http: FakeHTTP, max_mb=1, total_max_mb=4) -> FeishuIO:
    return FeishuIO(
        app_id="app-id",
        app_secret="secret",
        download_dir=tmp_path / "downloads",
        download_max_mb=max_mb,
        client=None,
        download_total_max_mb=total_max_mb,
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
                    "chat_id": "oc_current",
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

    payload = io.get_referenced_message_payload(
        {"parent_id": "om_source"},
        expected_chat_id="oc_current",
    )
    assert payload == {
        "message_id": "om_source",
        "message_type": "text",
        "content": {"text": "会议转录"},
    }
    assert io.get_tenant_access_token() == "token-1"
    assert len(http.post_calls) == 1


@pytest.mark.parametrize("message_type", ["text", "file"])
def test_referenced_message_rejects_cross_chat_access(tmp_path, message_type):
    message = {
        "code": 0,
        "data": {
            "items": [
                {
                    "message_id": "om_private",
                    "chat_id": "oc_private",
                    "msg_type": message_type,
                    "body": {"content": '{"text":"私密会议内容"}'},
                }
            ]
        },
    }
    io = make_io(
        tmp_path,
        FakeHTTP(
            get_responses=[FakeResponse(message)],
            post_responses=[token_response()],
        ),
    )

    with pytest.raises(
        ReferencedMessageAuthorizationError,
        match="引用消息不属于当前会话",
    ):
        io.get_referenced_message_payload(
            {"parent_id": "om_private"},
            expected_chat_id="oc_current",
        )


@pytest.mark.parametrize(
    ("expected_chat_id", "referenced_chat_id"),
    [
        ("", "oc_current"),
        ("oc_current", ""),
    ],
)
def test_referenced_message_rejects_missing_chat_context(
    tmp_path,
    expected_chat_id,
    referenced_chat_id,
):
    message = {
        "code": 0,
        "data": {
            "items": [
                {
                    "message_id": "om_source",
                    "chat_id": referenced_chat_id,
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

    with pytest.raises(
        ReferencedMessageAuthorizationError,
        match="无法验证引用消息是否属于当前会话",
    ):
        io.get_referenced_message_payload(
            {"parent_id": "om_source"},
            expected_chat_id=expected_chat_id,
        )
    if not expected_chat_id:
        assert http.get_calls == []


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

    assert path.name == "meeting_audio.m4a"
    assert path.parent.name.startswith("task-")
    assert path.read_bytes() == b"audio"


def test_same_name_downloads_get_distinct_task_directories(tmp_path):
    responses = [
        FakeResponse(chunks=[b"first"], headers={"Content-Length": "5"}),
        FakeResponse(chunks=[b"second"], headers={"Content-Length": "6"}),
    ]
    io = make_io(
        tmp_path,
        FakeHTTP(get_responses=responses, post_responses=[token_response()]),
    )

    first = io.download_message_resource("om_1", "key-1", "meeting.m4a")
    second = io.download_message_resource("om_2", "key-2", "meeting.m4a")

    assert first != second
    assert first.read_bytes() == b"first"
    assert second.read_bytes() == b"second"


def test_cleanup_download_removes_only_its_task_directory(tmp_path):
    io = make_io(
        tmp_path,
        FakeHTTP(
            get_responses=[FakeResponse(chunks=[b"audio"], headers={"Content-Length": "5"})],
            post_responses=[token_response()],
        ),
    )
    path = io.download_message_resource("om_1", "key", "meeting.m4a")
    task_dir = path.parent

    io.cleanup_download(path)

    assert not task_dir.exists()
    assert (tmp_path / "downloads").exists()


def test_download_rejects_when_aggregate_quota_would_be_exceeded(tmp_path):
    response = FakeResponse(
        chunks=[b"x"],
        headers={"Content-Length": str(2 * 1024 * 1024)},
    )
    io = make_io(
        tmp_path,
        FakeHTTP(get_responses=[response], post_responses=[token_response()]),
        max_mb=4,
        total_max_mb=1,
    )

    with pytest.raises(RuntimeError, match="临时下载目录空间不足"):
        io.download_message_resource("om_1", "key", "meeting.m4a")

    assert response.closed
