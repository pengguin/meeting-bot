import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import llm_backend
from llm_backend import (
    DEFAULT_API_BASES,
    SUPPORTED_PROVIDERS,
    extract_json_text,
    resolve_api_base,
    resolve_provider,
)


def test_default_provider_is_codex():
    assert resolve_provider() == "codex"


def test_supported_providers_cover_documented_backends():
    assert SUPPORTED_PROVIDERS == {
        "codex",
        "openai",
        "anthropic",
        "lm-studio",
        "ollama",
    }


def test_default_api_bases():
    assert resolve_api_base("openai") == "https://api.openai.com/v1"
    assert resolve_api_base("anthropic") == "https://api.anthropic.com"
    assert resolve_api_base("lm-studio") == "http://127.0.0.1:1234/v1"
    assert resolve_api_base("ollama") == "http://127.0.0.1:11434/v1"
    assert set(DEFAULT_API_BASES) == SUPPORTED_PROVIDERS - {"codex"}


def test_resolve_model_openai_requires_explicit_model():
    with pytest.raises(RuntimeError):
        llm_backend.resolve_model("openai")


def test_resolve_model_anthropic_has_default():
    assert llm_backend.resolve_model("anthropic").startswith("claude")


def test_extract_json_text_passthrough():
    raw = '{"a": 1}'
    assert extract_json_text(raw) == raw


def test_extract_json_text_strips_markdown_fence():
    raw = '```json\n{"a": 1}\n```'
    assert extract_json_text(raw) == '{"a": 1}'


def test_extract_json_text_strips_bare_fence():
    raw = '```\n{"a": 1}\n```'
    assert extract_json_text(raw) == '{"a": 1}'


def test_extract_json_text_slices_prose_wrapped_object():
    raw = '好的，以下是结果：\n{"a": {"b": 2}}\n如有问题请告知。'
    assert extract_json_text(raw) == '{"a": {"b": 2}}'
