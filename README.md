# 会议纪要助手

> 当前 `0.7.2 build 38` 是最后一代 Python 架构候选版，正在按 `docs/RELEASE_0.7_CLOSURE_PLAN.md` 执行封版验证。后续功能开发转入独立的 1.0 原生重构工作区 `/Users/Peng/Developer/meeting-bot-1.0-native`；P1 合同固化已完成，正式功能仍需等待架构 PoC 和设计评审。

会议纪要助手是一个本地运行的飞书会议助手。它接收飞书中的会议录音或转录文字材料，在本机完成音频处理、转写、说话人分离、会议类型识别和纪要生成，并输出 HTML、DOCX、MD、PDF 等正式会议纪要文件。

## 组成

- `bot.py`：飞书机器人后台入口。
- `feishu_io.py`：飞书凭据缓存、消息读取、资源下载、文件上传和回复。
- `audio_pipeline.py`：音频转换、ASR/说话人模型生命周期、转写和分离流水线。
- `runtime_status.py`：运行状态与会议完成事件的原子持久化。
- `asr_runtime.py`：faster-whisper 模型、线程、批量转写和解码参数的统一入口。
- `diarization_runtime.py`：说话人分离设备选择及 Apple GPU/CPU 回退逻辑。
- `transcription_progress.py`：语音转写百分比和已处理时长计算。
- `llm_backend.py`：纪要生成 LLM 后端抽象（Codex CLI / OpenAI 兼容 API / Anthropic / LM Studio / Ollama）。
- `speaker_naming.py`：匿名说话人标签的统一编号规则。
- `MeetingBotMenuBarApp/`：macOS 菜单栏 App，用于安装、状态查看、服务控制和会议库管理。
- `scripts/`：安装、自检、本地新增会议、重生成和补导出文件脚本。
- `schemas/`：会议分类和会议报告的结构化输出 schema。
- `docs/`：安装、升级、使用说明、0.7 封版计划、更新记录和开发路线图。
- `tests/`：核心导出、会话复用、转录材料解析、转写进度、说话人显示和 LLM 后端测试。

## 隐私边界

本仓库只应保存源码、脚本、文档、schema 和测试。以下内容不应提交到 Git：

- `.env`：真实飞书、Hugging Face、工具路径等本地配置。
- `.venv/`：本地 Python 虚拟环境。
- `sessions/`、`downloads/`、`runtime/`、`library/`、`tmp/`：会议材料、转录、纪要、运行状态和用户元数据。
- `dist/`：本地构建的安装盘、App 和发布产物。
- `backups/`：历史本地备份和旧版本代码快照。

提交前请参考 `docs/PRIVACY_AND_GIT.md`。

## 本地配置

复制配置样例并填写本机凭据：

```bash
cp .env.example .env
```

`.env` 包含真实密钥，已被 `.gitignore` 排除。不要把 `.env` 内容粘贴到 issue、PR、提交信息或公开文档中。

推荐的 Apple Silicon 转写配置：

```bash
ASR_MODEL=medium
ASR_LANGUAGE=zh
ASR_CPU_THREADS=16
ASR_BATCH_SIZE=8
ASR_BEAM_SIZE=5
```

### 纪要生成 LLM 后端

纪要生成默认使用本机 Codex CLI，也可以切换到其他后端（在 `.env` 或 App 设置页中配置）：

```bash
# 可选 codex / openai / anthropic / lm-studio / ollama
LLM_PROVIDER=codex
LLM_API_BASE=        # 留空使用所选后端默认地址
LLM_API_KEY=         # openai / anthropic 必填
LLM_MODEL=           # openai 兼容服务必填；本地服务可留空自动选择
```

- `openai`：任意兼容 OpenAI Chat Completions 协议的服务（OpenAI、DeepSeek、Kimi、通义千问、智谱等），把 `LLM_API_BASE` 指向对应服务地址即可。
- `anthropic`：Anthropic Messages API，模型默认 `claude-sonnet-4-6`。
- `lm-studio` / `ollama`：本地部署服务，分别默认连接 `127.0.0.1:1234` 和 `127.0.0.1:11434` 的 OpenAI 兼容端口；`LLM_MODEL` 留空时自动使用服务端已加载的模型。

## 常用验证

测试依赖放在 `requirements-dev.txt`。本地开发可使用项目虚拟环境；已安装版 App 的运行环境默认位于 `$HOME/Library/Application Support/meeting-bot/.venv`。

```bash
python3 -m pip install -r requirements-dev.txt
python3 -m pytest tests -q
bash -n scripts/install.sh scripts/build_setup_package.sh scripts/build_wheelhouse.sh scripts/doctor.sh scripts/install_optional_tools.sh scripts/preflight.sh scripts/upgrade.sh start_bot.sh
python3 -m py_compile scripts/create_local_meeting.py scripts/regenerate_session.py scripts/export_session_file.py scripts/generate_release_manifest.py scripts/data_recovery.py scripts/task_control.py bot.py feishu_io.py audio_pipeline.py runtime_status.py durable_storage.py task_ledger.py task_runtime.py asr_runtime.py diarization_runtime.py transcription_progress.py llm_backend.py speaker_naming.py meetingbot_config.py report_export.py report_generation.py session_store.py transcript_material.py
```

## 发布

发布包由本地脚本生成，产物默认进入 `dist/`。`dist/` 不入库，需要发布时重新生成。

```bash
bash MeetingBotMenuBarApp/build_release_app.sh
bash scripts/build_setup_package.sh
```

构建 App 时会在载荷内生成逐文件 SHA-256 清单；构建安装盘后会生成同版本的 `release-manifest-<version>.json`。正式发布环境可通过 `MEETINGBOT_RELEASE_SIGNING_KEY` 和 `MEETINGBOT_RELEASE_PUBLIC_KEY` 附加 ECDSA P-256/SHA-256 签名。当前开发路线见 `docs/DEVELOPMENT_ROADMAP.md`。

## 协作方式

建议先使用 GitHub private repository。多人协作时使用分支和 Pull Request，避免直接在主分支提交未经检查的改动。
