# 会议纪要助手 0.7.2 安装文档

## 配套文档

- 安装与升级说明：`docs/SETUP_GUIDE.html`
- 使用说明：`docs/SOFTWARE_GUIDE.html`
- 分享清单：`docs/SHARE_CHECKLIST.md`
- 开发路线图：`docs/DEVELOPMENT_ROADMAP.md`

## 支持环境

- macOS 14 或更高版本。
- Apple Silicon Mac 优先支持。
- Python 3.12 或更高版本。
- 已安装飞书客户端并具备企业自建应用配置权限。

## 安装前准备

需要提前准备这些账号和工具：

- 飞书开放平台企业自建应用。
- Hugging Face Token。
- 纪要生成 LLM 后端：默认 Codex CLI，也可使用 OpenAI 兼容 API、Anthropic、LM Studio 或 Ollama。
- `ffmpeg`。
- LibreOffice。

可用 Homebrew 安装系统工具：

```bash
brew install ffmpeg libreoffice
```

如果使用默认 `codex` 后端，Codex CLI 安装和登录请按当前 OpenAI/Codex CLI 指引完成。安装后确认终端中可运行：

```bash
codex --version
```

## 飞书应用配置

在飞书开放平台创建企业自建应用后，至少完成以下配置：

1. 获取 `FEISHU_APP_ID` 和 `FEISHU_APP_SECRET`。
2. 启用机器人能力。
3. 发布应用或在测试企业中启用。
4. 订阅消息事件：接收消息 v2.0。
5. 将机器人加入私聊或测试群。
6. 确认应用有读取消息资源、回复消息、上传文件所需权限。

## Hugging Face 配置

1. 创建 Hugging Face Token。
2. 接受 `pyannote/speaker-diarization-community-1` 模型使用条款。
3. 在 App 的首次启动向导或“设置 -> 高级设置”中填写 Token；0.4.0 起会保存到 macOS 系统钥匙串。

## 半自动安装

### 推荐方式：二合一图形化安装盘

默认分发物为 `会议纪要助手 0.7.2 安装盘.dmg`。其中包含：

- `会议纪要助手.app`
- `会议纪要助手卸载器.app`
- `Applications` 快捷入口
- `说明文档/安装与升级说明.html`
- `说明文档/使用说明.html`
- `说明文档/更新记录.md`
- `说明文档/开发路线图.md`

使用方式：

1. 双击打开 `会议纪要助手 0.7.2 安装盘.dmg`。
2. 将 `会议纪要助手.app` 拖入 `Applications`。
3. 在“应用程序”中首次打开 App。
4. App 会自动判断当前用户目录中是否已有安装：
   - 没有：执行首次部署流程。
   - 已有：先提示本机已安装版本，再执行保留数据的升级流程。
5. 若是首次安装，继续完成 App 内的首次启动配置向导。

### 首次启动时自动完成

首次从 `Applications` 打开后，App 会自动完成：

- 为当前用户创建 `$HOME/Library/Application Support/meeting-bot`。
- 按“复用已有环境 -> 离线 wheelhouse -> 在线安装”的顺序准备 Python 依赖。
- 创建运行目录和 LaunchAgent。
- 保留已有 `.env`、历史会议、日志、`library/` 和本地模板。

说明：

- 安装器不会替你填写密钥，也不会替你登录外部 LLM 服务；使用默认 Codex 后端时，仍需本人完成 Codex CLI 登录。
- 如果机器上只检测到低版本 Python，首次启动安装窗口会直接提供三种路径：
  - 自动在线安装独立 Python 3.12 运行时，并在项目中创建专用虚拟环境；不会替换系统 Python。
  - 选择本地离线 Python 安装包。
  - 指定已经安装好的 Python，可直接选择现有虚拟环境中的 `bin/python`。
- 如果缺少 `ffmpeg`、LibreOffice 或默认后端所需的 Codex CLI，首次启动安装窗口会提供“自动安装缺失工具”：
  - `ffmpeg` 和 LibreOffice 通过 Homebrew 安装。
  - Codex CLI 可自动安装，但登录仍需本人完成；若改用其他 LLM 后端，则按对应服务填写 API 地址、Key 和模型。
  - 若机器尚无 Homebrew，App 会提供 `brew.sh` 官方入口；为避免未经确认执行网络脚本，不会自动安装 Homebrew。完成官方安装后返回重试即可。
- 首次启动安装仍需要网络下载 Python 依赖；若本机没有 Python 3.12+，可由 App 自动在线准备独立运行时。
- 当前安装包未做 Developer ID 签名和公证；首次在其他电脑上打开时，macOS 可能会给出安全提示。
- 0.5.0 的 App 内载荷包含逐文件 SHA-256 清单。首次部署或升级会先完成完整性校验，再备份和覆盖旧版；校验失败时当前版本不会被改动。

### 依赖安装策略

安装脚本支持 5 种模式：

- `auto`：默认模式。若已有可用 `.venv`，直接复用；若发行包内包含 `wheelhouse/`，优先离线安装；否则在线安装。
- `reuse`：只复用已有 `.venv`，适合升级或已提前准备好环境的电脑。
- `offline`：只从 `wheelhouse/` 离线安装，适合封闭网络或批量分发。
- `online`：强制联网创建/更新虚拟环境。
- `managed-online`：通过固定版本且校验安装脚本 SHA-256 的 uv 自动准备独立 Python 3.12 运行时，再创建项目专用虚拟环境。

命令行示例：

```bash
bash scripts/install.sh --dependency-mode auto
bash scripts/install.sh --dependency-mode reuse
bash scripts/install.sh --dependency-mode offline
bash scripts/install.sh --dependency-mode online
bash scripts/install.sh --dependency-mode managed-online
```

若只需检查 App 内安装载荷是否完整，不执行安装：

```bash
bash scripts/install.sh --verify-payload-only
```

如果需要制作离线包，可在一台能联网的同类机器上先运行：

```bash
bash scripts/build_wheelhouse.sh
```

生成的 `wheelhouse/` 会被自动带入发行包，之后可在目标机器上用 `offline` 模式安装。

### 安装前检查

安装器和命令行安装都会先检查：

- macOS 是否达到 14 或更高版本
- 是否为 Apple Silicon
- 内存是否至少 8GB
- 可用磁盘空间是否至少 8GB
- 是否存在 Python 3.12 或更高版本

内存低于 16GB、磁盘空间低于 12GB，以及缺少 `ffmpeg`、LibreOffice 或当前选择的纪要生成后端配置时，会给出警告；硬性条件不满足时，安装会直接停止。

### 备用方式：命令行安装

解压发行包后进入目录，运行：

```bash
bash scripts/install.sh
```

可选参数：

```bash
bash scripts/install.sh --no-start
bash scripts/install.sh --install-dir "$HOME/Library/Application Support/meeting-bot"
bash scripts/install.sh --skip-app-build
bash scripts/install.sh --skip-app-install
bash scripts/install.sh --dependency-mode offline
```

安装脚本会自动执行：

- 复制后台支持文件到 `$HOME/Library/Application Support/meeting-bot`。
- 创建本地 Python 虚拟环境 `.venv`。
- 安装 `requirements.txt` 中的 Python 依赖。
- 创建运行目录：`downloads/`、`sessions/`、`runtime/`、`tmp/`，并把日志写到 `$HOME/Library/Logs/meeting-bot`。
- 若 `.env` 不存在，则从 `.env.example` 生成。
- 构建或安装菜单栏 App。
- 写入 LaunchAgent：`$HOME/Library/LaunchAgents/com.pgui.feishu-meeting-bot.plist`。
- 在 `.env` 已填完整时启用并加载后台服务；若仍是占位配置，则只完成安装，不直接启动。

安装脚本不会替你填写飞书 App ID、App Secret、Hugging Face Token 或 LLM API Key，也不会替你登录 Codex CLI。

安装完成后建议先运行：

```bash
bash "$HOME/Library/Application Support/meeting-bot/scripts/doctor.sh"
```

自检会检查 Python 虚拟环境、`ffmpeg`、LibreOffice、纪要生成后端、`.env` 和 LaunchAgent 配置。

首次打开 App 时，还会自动进入“首次启动配置”向导。向导会依次完成：

1. 系统条件和运行环境检查。
2. 确认本地录音和会议纪要保存位置；默认分别为 `$HOME/Library/Application Support/meeting-bot/downloads` 和 `$HOME/Library/Application Support/meeting-bot/sessions`，也可在全新安装时直接定制。
3. 飞书 App ID、App Secret、Hugging Face Token 等配置填写。
4. 飞书接口、Hugging Face 模型访问和纪要生成后端连通性检查。

如果希望先了解整体功能，再开始安装，可先打开 `docs/SOFTWARE_GUIDE.html`。

## 从旧版本升级

如果已经安装并运行过旧版，仍然优先使用 `会议纪要助手 0.7.2 安装盘.dmg`。把新版 App 拖入 `Applications` 覆盖旧版后，再打开 App，程序会自动识别为升级路径；如果旧版仍在 `$HOME/Library/Application Support/meetin-bot`、`$HOME/Library/Application Support/feishu-meeting-bot`、`$HOME/meetin-bot`、`$HOME/meeting-bot` 或 `$HOME/feishu-meeting-bot`，会把 `.env`、虚拟环境和用户数据迁移到新的 `$HOME/Library/Application Support/meeting-bot`，并把旧根目录下的日志迁到 `$HOME/Library/Logs/meeting-bot`。

0.4.0 起，升级过程会分别备份运行组件、Python 环境和已安装 App。0.5.0 在备份前增加载荷完整性校验。任一阶段失败时会自动恢复旧版，`sessions/`、`downloads/`、`library/`、运行状态和本地配置不会被覆盖；安装窗口会显示失败阶段与恢复结果。

它会在保留 `.env`、已有保存位置、历史会议、日志、`library/` 和本地模板的前提下更新程序文件、菜单栏 App 与 LaunchAgent。详细步骤见 `docs/UPGRADE_GUIDE.md`。

## 填写本地配置

推荐在 App 的首次启动向导或“设置 -> 高级设置”中填写配置。0.4.0 起，飞书 App Secret、Hugging Face Token 和 LLM API Key 会写入 macOS 系统钥匙串；`.env` 只保留非敏感运行参数，并限制为当前用户读写。

命令行安装仍兼容直接编辑：

```bash
$HOME/Library/Application Support/meeting-bot/.env
```

至少填写：

```bash
FEISHU_APP_ID=cli_xxxxxxxxxxxxxxxx
FEISHU_APP_SECRET=replace_with_feishu_app_secret
HF_TOKEN=hf_replace_with_your_token
CODEX_BIN=codex
```

语音转写性能参数可选；Apple Silicon 推荐保留默认值：

```bash
ASR_MODEL=medium
ASR_LANGUAGE=zh
ASR_CPU_THREADS=16
ASR_BATCH_SIZE=8
ASR_BEAM_SIZE=5
```

其中 `ASR_CPU_THREADS` 和 `ASR_BATCH_SIZE` 控制 faster-whisper 的 CPU 并行与批量转写；增加数值会提高资源占用。说话人分离会自动优先使用 Apple GPU，无需额外配置。

如果 `codex` 不在 LaunchAgent 的 PATH 中，建议填写绝对路径：

```bash
CODEX_BIN=/opt/homebrew/bin/codex
```

纪要生成默认使用 Codex CLI。若要切换到其他后端，可继续填写：

```bash
# 可选 codex / openai / anthropic / lm-studio / ollama
LLM_PROVIDER=codex
LLM_API_BASE=
LLM_API_KEY=
LLM_MODEL=
LLM_TIMEOUT_SECONDS=600
```

`openai` 适用于 OpenAI、DeepSeek、Kimi、通义千问、智谱等兼容 Chat Completions 协议的服务；`lm-studio` 和 `ollama` 面向本机服务，模型名可留空并由服务端当前加载模型决定。

## 启动服务

填写 `.env` 后，可以通过菜单栏 App 点击“启动”或“重启”。

也可以用命令行启动：

```bash
launchctl enable gui/$(id -u)/com.pgui.feishu-meeting-bot
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/com.pgui.feishu-meeting-bot.plist"
launchctl kickstart -k gui/$(id -u)/com.pgui.feishu-meeting-bot
```

查看状态：

```bash
launchctl print gui/$(id -u)/com.pgui.feishu-meeting-bot
cat "$HOME/Library/Application Support/meeting-bot/runtime/status.json"
```

查看日志：

```bash
tail -f "$HOME/Library/Logs/meeting-bot/bot_stdout.log"
tail -f "$HOME/Library/Logs/meeting-bot/bot_stderr.log"
```

## 构建安装盘

在项目根目录运行：

```bash
bash scripts/build_setup_package.sh
```

脚本会：

- 重新构建菜单栏 App。
- 排除 `.git`、本地运行数据和密钥，并在完整安装时清理旧 App 资源残留。
- 生成默认交付物 `dist/会议纪要助手 0.7.2 安装盘.dmg`。
- 把安装与升级说明、使用说明、更新记录和开发路线图一并放入安装盘。
- 同步在 `dist/` 下生成线程交接汇总。
- 生成 `dist/release-manifest-0.7.2.json`，记录安装盘大小、SHA-256、版本和构建号；如配置 ECDSA P-256 发布密钥，同时生成签名文件。

## 卸载

1. 打开安装盘中的 `会议纪要助手卸载器.app`。
2. 检查扫描结果。卸载器只会处理能够证明属于本应用的 App、后台服务、安装载荷、环境、缓存和日志。
3. 默认保留会议资料。卸载器会先把应用管理的配置、会议库、录音、转录稿、纪要、备份和日志移动到用户选择的位置。
4. 如确实需要删除资料，单独勾选“删除应用管理的会议数据、配置和日志”；确认框会列出精确路径和预计大小，再进行第二次确认。
5. 安装目录外的自定义录音或纪要目录始终原地保留；无法证明归属的文件也不会删除。

命令行仅作为后台服务停止的故障排查手段：

```bash
launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/com.pgui.feishu-meeting-bot.plist"
rm "$HOME/Library/LaunchAgents/com.pgui.feishu-meeting-bot.plist"
```

不要手动删除整个自定义录音目录、纪要目录或来源不明的安装目录。

## 常见问题

### 菜单栏 App 显示未找到配置

确认 LaunchAgent 文件存在：

```bash
ls "$HOME/Library/LaunchAgents/com.pgui.feishu-meeting-bot.plist"
```

不存在时重新运行：

```bash
bash "$HOME/Library/Application Support/meeting-bot/scripts/install.sh"
```

### 新电脑上提示 `Bootstrap failed: 5`

先运行：

```bash
bash "$HOME/Library/Application Support/meeting-bot/scripts/doctor.sh"
```

若核心配置仍是占位值，先在 App 中完成设置再启动服务。0.4.0 版本的 App 在点击“启动”或“重启”时，会先尝试恢复被禁用的 LaunchAgent，再执行加载和启动；如果旧版本曾经把服务禁用过，升级后也可以自行恢复。

### PDF 未生成

确认 LibreOffice 可用：

```bash
/Applications/LibreOffice.app/Contents/MacOS/soffice --version
```

### 说话人分离失败

确认 `HF_TOKEN` 正确，并且 Hugging Face 账号已接受 pyannote 模型条款。

### 纪要生成后端执行失败

使用默认 Codex 后端时，确认 Codex CLI 已登录，并确认 `.env` 中的 `CODEX_BIN` 指向可执行文件。使用其他后端时，确认 `LLM_PROVIDER`、`LLM_API_BASE`、`LLM_API_KEY` 和 `LLM_MODEL` 与对应服务匹配。

### 需要把软件分享给别人

优先按 `docs/SHARE_CHECKLIST.md` 准备材料。至少需要提供发行包、安装说明、软件说明、依赖说明和 `.env.example`，但不要提供你自己的 `.env`、会议数据或日志。
