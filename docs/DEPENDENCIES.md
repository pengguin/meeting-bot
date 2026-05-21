# 会议纪要助手 0.2 依赖说明

## 一、Python 依赖

项目使用本地虚拟环境管理 Python 依赖。安装脚本当前支持三种实际路线：

- 复用已有且可用的 `.venv`
- 使用 `wheelhouse/` 离线安装
- 在线创建虚拟环境并安装依赖

默认 `auto` 模式会按上述顺序自动选择。手动准备时也可运行：

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
```

`requirements.txt` 中包含后台服务所需的主要 Python 包，例如：

- 飞书 SDK。
- 语音转写相关依赖。
- 说话人分离相关依赖。
- 文档和报告导出相关依赖。

## 二、系统工具

后台服务还依赖以下系统级工具：

- `ffmpeg`：把上传音频转换为 16 kHz 单声道 WAV，供后续分析使用。
- `LibreOffice` / `soffice`：把生成的 DOCX 文件转换为 PDF。
- `codex`：完成会议分类和结构化纪要生成。

在 macOS 上可通过 Homebrew 安装常见系统工具：

```bash
brew install ffmpeg libreoffice
```

Codex CLI 需要单独安装并完成登录。安装后应能在终端中运行：

```bash
codex --version
```

## 三、账号与密钥

运行时需要准备以下配置：

- `FEISHU_APP_ID`
- `FEISHU_APP_SECRET`
- `HF_TOKEN`

它们写在本机 `.env` 文件中，不应放入发行包，也不应上传到公开仓库。

## 四、可配置项

`.env` 还可配置以下本地参数：

- `ASR_MODEL`
- `ASR_LANGUAGE`
- `DIARIZATION_MODEL`
- `CODEX_BIN`
- `FFMPEG_BIN`
- `REPORT_BODY_FONT`
- `REPORT_HEADING_FONT`

如果系统工具不在默认 PATH 中，建议将 `CODEX_BIN` 或 `FFMPEG_BIN` 配置为绝对路径，例如：

```bash
CODEX_BIN=/opt/homebrew/bin/codex
FFMPEG_BIN=/opt/homebrew/bin/ffmpeg
```

## 五、后台服务配置

macOS 后台服务使用 LaunchAgent，配置文件默认位于：

```text
$HOME/Library/LaunchAgents/com.pgui.feishu-meeting-bot.plist
```

项目提供 `scripts/doctor.sh` 用于统一检查：

- macOS、芯片、内存、磁盘和 Python 版本。
- Python 虚拟环境。
- `ffmpeg`。
- LibreOffice。
- Codex CLI。
- `.env` 是否填写完整。
- LaunchAgent 是否存在。

若需要制作离线依赖包，可在同类 Apple Silicon macOS 机器上运行：

```bash
bash scripts/build_wheelhouse.sh
```

之后将生成的 `wheelhouse/` 与发行包一起分发，即可使用 `offline` 模式安装。
