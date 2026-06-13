"""纪要生成 LLM 后端抽象层。

支持五种后端，由 .env 中的 LLM_PROVIDER 选择：
- codex：本机 Codex CLI（默认，保持原有行为，结构由 --output-schema 强制约束）；
- openai：任意 OpenAI 兼容 Chat Completions 服务（OpenAI、DeepSeek、Kimi、
  通义千问、智谱等，配合 LLM_API_BASE / LLM_API_KEY / LLM_MODEL 使用）；
- anthropic：Anthropic Messages API；
- lm-studio / ollama：本地部署服务，走各自的 OpenAI 兼容端口，
  未指定 LLM_MODEL 时自动选用服务端加载的第一个模型。

HTTP 后端通过"提示词内嵌 JSON Schema + JSON mode"约束输出结构，
并在解析前剥除 markdown 围栏等噪声。
"""

import json
import re
import subprocess
from pathlib import Path
from typing import Dict, Optional

import requests

from meetingbot_config import (
    CODEX_BIN,
    LLM_API_BASE,
    LLM_API_KEY,
    LLM_MODEL,
    LLM_PROVIDER,
    LLM_TIMEOUT_SECONDS,
)

OPENAI_COMPATIBLE_PROVIDERS = {"openai", "lm-studio", "ollama"}
SUPPORTED_PROVIDERS = {"codex", "anthropic"} | OPENAI_COMPATIBLE_PROVIDERS

DEFAULT_API_BASES = {
    "openai": "https://api.openai.com/v1",
    "anthropic": "https://api.anthropic.com",
    "lm-studio": "http://127.0.0.1:1234/v1",
    "ollama": "http://127.0.0.1:11434/v1",
}

DEFAULT_MODELS = {
    "anthropic": "claude-sonnet-4-6",
}

_SYSTEM_PROMPT = "你是一名严谨的会议纪要结构化助手，始终只输出 JSON。"


def resolve_provider() -> str:
    if LLM_PROVIDER not in SUPPORTED_PROVIDERS:
        raise RuntimeError(
            f"不支持的 LLM_PROVIDER：{LLM_PROVIDER}；"
            f"可选值：{', '.join(sorted(SUPPORTED_PROVIDERS))}"
        )
    return LLM_PROVIDER


def resolve_api_base(provider: str) -> str:
    base = LLM_API_BASE or DEFAULT_API_BASES.get(provider, "")
    if not base:
        raise RuntimeError("LLM_API_BASE 为空，请在 .env 中配置 API 地址")
    return base.rstrip("/")


def resolve_model(provider: str) -> str:
    if LLM_MODEL:
        return LLM_MODEL
    if provider in DEFAULT_MODELS:
        return DEFAULT_MODELS[provider]
    if provider in {"lm-studio", "ollama"}:
        model = _first_available_local_model(provider)
        if model:
            return model
        raise RuntimeError(
            f"{provider} 未返回可用模型：请确认本地服务已启动并加载模型，"
            "或在 .env 中显式设置 LLM_MODEL"
        )
    raise RuntimeError("LLM_MODEL 为空，请在 .env 中指定模型名称")


def llm_runtime_description() -> str:
    provider = resolve_provider()
    if provider == "codex":
        return "Codex CLI"
    model = LLM_MODEL or DEFAULT_MODELS.get(provider, "自动选择模型")
    return f"{provider} / {model}"


def extract_json_text(raw: str) -> str:
    """从模型回复中提取 JSON 文本。

    依次尝试：剥除 markdown 代码块围栏；若仍非裸 JSON，
    截取首个 "{" 到最后一个 "}" 之间的内容。
    """
    text = raw.strip()

    fenced = re.search(r"```(?:json)?\s*\n?(.*?)\n?\s*```", text, re.DOTALL)
    if fenced:
        candidate = fenced.group(1).strip()
        if candidate.startswith("{"):
            text = candidate

    if text.startswith("{") and text.endswith("}"):
        return text

    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end > start:
        return text[start : end + 1]
    return text


def run_llm(
    prompt: str,
    output_path: Path,
    schema_path: Optional[Path] = None,
    timeout: int = 2400,
) -> str:
    """执行一次 LLM 生成，把 JSON 文本写入 output_path 并返回。

    timeout 参数沿用 Codex CLI 的语义；HTTP 后端统一使用
    LLM_TIMEOUT_SECONDS，避免本地小模型被过长超时拖住排队任务。
    """
    provider = resolve_provider()

    if provider == "codex":
        return _run_codex_cli(prompt, output_path, schema_path, timeout)

    if provider == "anthropic":
        raw = _run_anthropic(prompt, schema_path, LLM_TIMEOUT_SECONDS)
    else:
        raw = _run_openai_compatible(provider, prompt, schema_path, LLM_TIMEOUT_SECONDS)

    text = extract_json_text(raw)
    output_path.write_text(text, encoding="utf-8")
    return text


def _run_codex_cli(
    prompt: str,
    output_path: Path,
    schema_path: Optional[Path],
    timeout: int,
) -> str:
    cmd = [
        CODEX_BIN,
        "exec",
        "--skip-git-repo-check",
        "--sandbox",
        "read-only",
        "--ephemeral",
    ]

    if schema_path is not None:
        cmd.extend(["--output-schema", str(schema_path)])

    cmd.extend(["--output-last-message", str(output_path), "-"])

    result = subprocess.run(
        cmd,
        input=prompt,
        text=True,
        capture_output=True,
        timeout=timeout,
    )

    if result.returncode != 0:
        raise RuntimeError(
            "Codex 执行失败。\n"
            f"STDOUT:\n{result.stdout}\n"
            f"STDERR:\n{result.stderr}"
        )

    if not output_path.exists():
        raise RuntimeError(f"Codex 未生成输出文件：{output_path.name}")

    return output_path.read_text(encoding="utf-8").strip()


def _json_instructions(schema_path: Optional[Path]) -> str:
    lines = [
        "输出要求：",
        "- 只输出一个 JSON 对象本身；",
        "- 不要使用 markdown 代码块包裹；",
        "- 不要输出任何解释、前言或附加文字。",
    ]
    if schema_path is not None:
        lines.append("JSON 必须严格符合以下 JSON Schema：")
        lines.append(schema_path.read_text(encoding="utf-8"))
    return "\n".join(lines)


def _openai_headers() -> Dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if LLM_API_KEY:
        headers["Authorization"] = f"Bearer {LLM_API_KEY}"
    return headers


def _first_available_local_model(provider: str) -> str:
    base = resolve_api_base(provider)
    try:
        response = requests.get(
            f"{base}/models",
            headers=_openai_headers(),
            timeout=10,
        )
        response.raise_for_status()
        items = response.json().get("data", [])
    except (requests.RequestException, ValueError):
        return ""

    for item in items:
        model_id = str(item.get("id", "")).strip()
        if model_id:
            return model_id
    return ""


def _run_openai_compatible(
    provider: str,
    prompt: str,
    schema_path: Optional[Path],
    timeout: int,
) -> str:
    if provider == "openai" and not LLM_API_KEY:
        raise RuntimeError("LLM_API_KEY 为空：openai 兼容后端需要 API Key")

    base = resolve_api_base(provider)
    model = resolve_model(provider)
    url = f"{base}/chat/completions"
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": _SYSTEM_PROMPT},
            {
                "role": "user",
                "content": f"{prompt}\n\n{_json_instructions(schema_path)}",
            },
        ],
        "temperature": 0.2,
        "stream": False,
        "response_format": {"type": "json_object"},
    }

    response = requests.post(
        url, headers=_openai_headers(), json=payload, timeout=timeout
    )
    if response.status_code == 400 and "response_format" in response.text:
        # 个别 OpenAI 兼容服务不支持 JSON mode，去掉后重试一次。
        payload.pop("response_format", None)
        response = requests.post(
            url, headers=_openai_headers(), json=payload, timeout=timeout
        )

    if response.status_code != 200:
        raise RuntimeError(
            f"LLM 接口调用失败（{provider} HTTP {response.status_code}）："
            f"{response.text[:800]}"
        )

    data = response.json()
    try:
        content = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise RuntimeError(
            f"LLM 返回结构异常（{provider}）："
            f"{json.dumps(data, ensure_ascii=False)[:800]}"
        )

    if not isinstance(content, str) or not content.strip():
        raise RuntimeError(f"LLM 返回内容为空（{provider}）")
    return content


def _run_anthropic(
    prompt: str,
    schema_path: Optional[Path],
    timeout: int,
) -> str:
    if not LLM_API_KEY:
        raise RuntimeError("LLM_API_KEY 为空：anthropic 后端需要 API Key")

    base = resolve_api_base("anthropic")
    url = f"{base}/messages" if base.endswith("/v1") else f"{base}/v1/messages"
    headers = {
        "Content-Type": "application/json",
        "x-api-key": LLM_API_KEY,
        "anthropic-version": "2023-06-01",
    }
    payload = {
        "model": resolve_model("anthropic"),
        "max_tokens": 8192,
        "system": _SYSTEM_PROMPT,
        "messages": [
            {
                "role": "user",
                "content": f"{prompt}\n\n{_json_instructions(schema_path)}",
            },
        ],
    }

    response = requests.post(url, headers=headers, json=payload, timeout=timeout)
    if response.status_code != 200:
        raise RuntimeError(
            f"LLM 接口调用失败（anthropic HTTP {response.status_code}）："
            f"{response.text[:800]}"
        )

    data = response.json()
    text = "".join(
        part.get("text", "")
        for part in data.get("content", [])
        if isinstance(part, dict) and part.get("type") == "text"
    )
    if not text.strip():
        raise RuntimeError("LLM 返回内容为空（anthropic）")
    return text
