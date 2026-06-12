# 会议纪要助手

会议纪要助手是一个本地运行的飞书会议助手。它接收飞书中的会议录音或转录文字材料，在本机完成音频处理、转写、说话人分离、会议类型识别和纪要生成，并输出 HTML、DOCX、MD、PDF 等正式会议纪要文件。

## 组成

- `bot.py`：飞书机器人后台入口。
- `asr_runtime.py`：faster-whisper 模型、线程、批量转写和解码参数的统一入口。
- `diarization_runtime.py`：说话人分离设备选择及 Apple GPU/CPU 回退逻辑。
- `transcription_progress.py`：语音转写百分比和已处理时长计算。
- `MeetingBotMenuBarApp/`：macOS 菜单栏 App，用于安装、状态查看、服务控制和会议库管理。
- `scripts/`：安装、自检、本地新增会议、重生成和补导出文件脚本。
- `schemas/`：会议分类和会议报告的结构化输出 schema。
- `docs/`：安装、升级、使用说明和更新记录。
- `tests/`：核心导出、会话复用和转录材料解析测试。

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

## 常用验证

```bash
python3 -m pytest tests
bash -n scripts/install.sh scripts/build_setup_package.sh scripts/build_wheelhouse.sh scripts/doctor.sh scripts/install_optional_tools.sh scripts/preflight.sh scripts/upgrade.sh start_bot.sh
python3 -m py_compile scripts/create_local_meeting.py scripts/regenerate_session.py scripts/export_session_file.py bot.py asr_runtime.py diarization_runtime.py transcription_progress.py meetingbot_config.py report_export.py report_generation.py session_store.py transcript_material.py
```

## 发布

发布包由本地脚本生成，产物默认进入 `dist/`。`dist/` 不入库，需要发布时重新生成。

```bash
bash MeetingBotMenuBarApp/build_release_app.sh
bash scripts/build_setup_package.sh
```

## 协作方式

建议先使用 GitHub private repository。多人协作时使用分支和 Pull Request，避免直接在主分支提交未经检查的改动。
