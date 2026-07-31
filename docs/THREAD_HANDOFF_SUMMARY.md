# 会议纪要助手 线程交接总结

生成时间：2026-05-18（2026-07-31 更新至 0.7 封版与 1.0 原生重构交接）

本文档用于帮助新线程中的 agent 快速理解本轮开发上下文、已完成工作、关键文件和后续开发入口。

## 项目概览

`~/Developer/meeting-bot` 是当前开发目录，用于开发一个本地运行的小型软件项目：通过飞书机器人接收会议录音或转录文本，在本机完成转写、说话人分离、会议纪要生成，并将正式纪要文件回传到飞书。旧路径 `~/feishu-meeting-bot` 目前保留为指向该目录的快捷入口。

项目由两部分组成：

- Python 后台服务：`bot.py`，通过飞书长连接接收消息，执行音频处理、转写、纪要生成、文件上传。
- macOS 菜单栏 App：`MeetingBotMenuBarApp/`，用于查看后台状态、打开结果文件、启动/停止/重启服务、控制开机启动和系统通知。

后台运行依赖：

- 飞书开放平台企业自建应用。
- Hugging Face Token，用于 pyannote 说话人分离。
- faster-whisper，用于 ASR。
- 纪要生成 LLM 后端：默认 Codex CLI，也可切换到 OpenAI 兼容 API、Anthropic、LM Studio 或 Ollama。
- ffmpeg，用于音频转换。
- LibreOffice，用于 DOCX 转 PDF。

## 本轮主要工作

### 当前主线状态（2026-07-31 / 0.7.2 build 38 封版候选）

本地 `main` 已以 UI 分支为后续主线，0.4.0 完成可续跑流程与事务式安装，0.5.0 按路线图完成核心模块拆分、会议库后台增量索引与发布完整性链路。旧主线基线 `3303606` 仅作为历史远端分支保留，不再作为后续开发入口。

当前主线已包含以下能力和约定：

- macOS App 采用新的原生 UI：顶部 `概览 / 会议库` 分段切换、会议库 `NavigationSplitView` 三栏、原生搜索、固定工具栏和品牌青绿色强调色。
- 纪要生成不再绑定单一 Codex CLI；`llm_backend.py` 支持 `codex`、`openai`、`anthropic`、`lm-studio`、`ollama`，设置页和首次启动向导可配置后端。
- 会议处理状态栏动画基于用户原有声波或脉冲图标播放，不再在生成纪要时切换为带圈声波。
- 本地新增会议支持录音和转录稿拖拽，提交后立即建立临时会议条目；关闭新增窗口后仍在主窗口底部显示进度并提供“暂停”。
- 说话人分离和语音转写均有实时进度；Apple Silicon 说话人分离优先 MPS，不兼容步骤回退 CPU。
- 说话人显示统一为 `SPEAKER_00 -> 说话人1`、`UNKNOWN -> 未知说话人`；保存真实姓名后会同步重生成转录稿、会议纪要和已有导出文件。
- 原始转录音频拖动改为预览时间、松手后一次性跳转，降低长音频播放进度条卡顿。
- 发布脚本、Xcode、升级脚本、安装盘脚本和卸载器当前版本均为 `0.7.2`、构建号 `38`。
- 卸载器采用所有权白名单和载荷清单逐文件清理；删除资料前列出受管路径与预计大小，外部自定义目录、源码仓库和 1.0 重构目录不进入删除范围。
- 安装盘同时交付主 App 和图形化卸载器；正式模式缺少 Developer ID 签名身份时，两者任一构建都会失败关闭。
- `0.3.1` 修复会议库配色实时联动：列表图标、选中背景、标签、日期筛选、原始转录活动段落和会议条目右侧“已生成纪要”状态圆点均跟随设置页蓝 / 绿 / 灰配色刷新。
- `0.3.2` 在本地新增会议非主动中止失败时保留草稿：已有转录稿可重试生成纪要，只有原始录音可在原会话目录重新处理；崩溃遗留的处理中草稿会通过任务锁恢复为可操作状态。
- `0.4.0` 将草稿扩展为阶段检查点流程：暂停、崩溃或 App 重开后复用已完成的音频预处理、说话人分离、转写、对齐、分类和纪要产物；纪要失败可沿用原格式重试。
- LLM 输出增加结构校验、原子写入、有限重试和登录 / 额度 / 限流 / 网络 / 格式错误分类；转录结果不会因纪要后端失败而删除。
- 飞书后台使用有上限任务队列、跨重启消息去重、按需加载模型、访问凭据缓存和下载大小限制，降低空闲资源与失控并发风险。
- 敏感凭据迁入 macOS 系统钥匙串；升级对代码、Python 环境和 App 分别备份，失败时自动恢复并保留会议数据。
- `0.5.0` 将飞书 I/O、音频流水线和运行状态迁出 `bot.py`，并以集成测试覆盖消息引用、流式下载、模型复用、进度回调和状态原子写入。
- 会议库扫描已迁入 Swift actor，使用会话目录指纹缓存未变化记录；扫描时主界面保持可操作，并合并重复刷新请求。
- App 内载荷包含逐文件 SHA-256 清单；安装器在备份或覆盖旧版前校验。安装盘构建后生成机器可读发布清单，并预留 ECDSA P-256/SHA-256 签名入口。
- `0.5.1` 修复后台启动入口调用已删除旧函数导致的 LaunchAgent 重启循环；界面停止状态不再显示陈旧的“运行中”消息。
- `0.5.2` 修复飞书跨会话引用、载荷与卸载边界、元数据损坏覆盖和 LLM 本地执行权限风险；依赖检测支持非 Homebrew 安装入口。
- `0.6.0` 建立统一持久化层和数据版本：会议元数据、草稿、检查点及运行状态具备文件锁、原子替换、备份、损坏写保护和显式恢复工具。
- `0.7.0` 建立本地与飞书共用的持久化任务账本、有限状态机、幂等提交和重启审计；本地暂停重试复用原任务及检查点。
- 开发测试依赖新增 `requirements-dev.txt`；App 虚拟环境中已安装 pytest，`tests/` 目前覆盖 ASR 参数、中文简体转换、说话人分离 MPS 回退、说话人显示同步、转写进度和 LLM 后端。

本轮新增或纳入提交的测试文件：

- `tests/test_asr_runtime.py`
- `tests/test_chinese_text.py`
- `tests/test_diarization_runtime.py`
- `tests/test_speaker_labels.py`
- `tests/test_transcription_progress.py`
- `tests/test_local_meeting_drafts.py`
- `tests/test_llm_backend.py`
- `tests/test_task_runtime.py`
- `tests/test_feishu_io.py`
- `tests/test_audio_pipeline.py`
- `tests/test_runtime_status.py`
- `tests/test_release_manifest.py`

### 0.2.14 修订轮次

本轮修正 0.2.13 之后的文件按钮刷新和主窗口底部状态栏：

- `MeetingLibraryStore.latestMarkdownSummary` 改为按“匿名版/实名版”导出标记识别 Markdown 纪要，避免标题为“讨论纪要”等文件名时补生成 MD 后仍被视为未生成，同时避免把用户上传的原始 `.md` 转录稿误当成导出纪要。
- 概览页「最近一次会议」的文件按钮改为优先读取 `MeetingLibraryStore` 中对应 `MeetingRecord` 的最新文件路径，补生成后会跟随会议库扫描结果更新。
- 主窗口底部新增统一状态栏；概览 tab 显示版本号，会议库 tab 显示刷新按钮和当前筛选/总会议数。

### 0.2.13 修订轮次

本轮修正 0.2.12 之后的文件按钮细节：

- `LibraryFileButton` 对“文件未生成但可右键生成”的状态恢复灰化视觉，避免和已生成文件按钮显示一致；为保留右键菜单，按钮本身仍保持可接收右键事件，左键点击缺失文件时只提示无可打开文件。
- 概览页「最近一次会议」的 HTML、DOCX、MD、PDF 文件按钮接入 `MeetingLibraryStore.generateExport`，会按最近会议 `sessionID` 找到对应 `MeetingRecord`，缺失文件时右键提供「生成文件」。
- 概览页出现时会刷新会议库，保证最近会议可以映射到会议库记录。

### 0.2.12 修订轮次

本轮继续处理长时间驻留卡顿、状态栏图标选项、会议库选择和升级环境校验：

- `BotRuntimeStore` 的周期刷新改为后台队列执行，主线程只接收结果；状态栏图标与弹窗尺寸更新增加 120ms 节流，并且仅在弹窗显示时重算弹窗尺寸，降低长时间驻留后 UI 被周期检查拖慢的风险。
- 设置页「外观」移除第三类状态栏图标「状态徽标」和颜色策略「跟随菜单栏」；旧偏好值会自动回退到声波/白色。
- 状态栏图标仍按任务状态临时切换为完成或异常图标，但点击状态栏、打开主界面、重新激活 App 或点击通知后，会把当前完成/异常状态标记为已读并恢复默认状态图标。
- `MeetingLibraryStore.selectMeeting` 修正多选：`Shift` 现在按当前锚点到目标行做范围选择，`Command` / `Control` 才是逐项增减选择。
- 会议列表右键首项改为「打开文件夹」。
- 新增 `scripts/export_session_file.py`，可直接从既有 `report_named.json` / `report_anon.json` 补导出 HTML、DOCX、MD、PDF，不重新调用会议分析；会议详情文件按钮在缺失文件时右键只显示「生成文件」。
- 安装/升级脚本和 App 路径增加旧 `~/Library/Application Support/meetin-bot`、`~/Library/Application Support/feishu-meeting-bot` 探测；历史 `.venv` 复用会先确认 Python >= 3.12，避免旧 Python 触发当前脚本语法错误。
- `EnvironmentHealth.swift`、`scripts/preflight.sh`、`scripts/install.sh`、`scripts/doctor.sh` 对 Codex CLI 的检查从“命令存在”升级为 `codex login status` 登录状态校验。

### 0.2.11 修订轮次

本轮继续修正设置页外观和会议类型设置：

- 状态栏图标颜色不再依赖 `NSStatusBarButton.contentTintColor`；白色/黑色模式会直接生成对应颜色的非模板 `NSImage`，跟随菜单栏模式才保留模板图交由 macOS 渲染。
- 「外观 -> 状态栏图标 -> 图标方案」改为三枚可视化图标按钮，分别对应声波、脉冲、状态徽标，不再只显示文字。
- 「纪要设置 -> 会议类型」左侧列表高度从 220 增至 320，底部按钮改为 `类别`、`类型`、`删除`，并按列表宽度分散对齐。
- 设置页通用 `settingsCard` 改为标题在框体外显示，标题字号比框体内正文大 2pt，强化「版本」「环境检查」等分区层级。

### 0.2.10 修订轮次

本轮继续修正 0.2.9 发布后的外观和新增会议体验：

- `AppAppearance` 在「自动」模式下不再返回空外观，而是读取当前 macOS `AppleInterfaceStyle` 后显式套用 Aqua 或 Dark Aqua；窗口标题栏、内容区和 SwiftUI `preferredColorScheme` 会保持同一套浅色/深色外观。
- 设置页「外观」新增状态栏图标设置：`StatusBarIconStyle` 提供声波、脉冲、状态徽标三套 SF Symbols 图标方案；`StatusBarIconColorMode` 提供白色、黑色、跟随菜单栏三种颜色策略，默认白色。
- `MeetingBotMenuBarAppApp.swift` 监听 `UserDefaults.didChangeNotification` 和系统外观变化，设置页调整图标方案或颜色后会立即刷新状态栏图标。
- 新增会议完成后，`MeetingLibraryStore.createLocalMeeting` 会把 `LocalMeetingCreationResult` 回传给窗口；App 会关闭新增会议窗口、打开主界面，并依靠原有 `selectMeeting(sessionID:)` 定位到新纪要。
- `NewMeetingWindowView` 增加「完成后打开纪要文件」下拉选项：不自动打开、HTML、DOCX、MD、PDF。选择某个格式时会自动保证该格式进入导出集合。

### 0.2.9 修订轮次

本轮检查了 `~/Developer/meeting-bot/backups/claude修改0.2.9` 中基于 0.2.8 的修复。备份中存在三类不能直接覆盖当前主线的问题：部分脚本仍写 `0.2.8`，App 内嵌资源路径仍有 `bootstrap/feishu-meeting-bot`，交接文档仍指向旧开发目录和已清理的旧打包流程。因此本轮只合并有效修复，并保留当前主线已整理的 `bootstrap/meeting-bot`、`docs/DEPENDENCIES.md`、拖拽式 DMG 发布流程和开发目录 `~/Developer/meeting-bot`。

0.2.9 已合并的修复：

- `scripts/install.sh` 扩展 Python 探测：新增 pyenv、python.org 官方安装包、安装目录与历史安装目录里的 `.venv`，并可在非在线强制模式下复用历史虚拟环境，减少重复联网安装。
- `scripts/create_local_meeting.py` 新增进度 JSON 输出；`MeetingLibraryStore.createLocalMeeting` 改为流式读取 stdout/stderr，新增会议窗口可实时显示导入、转换、转写、生成纪要和导出阶段。
- `scripts/regenerate_session.py` 新增 `--speaker-map-file`，重生成会议模板时会把会议库中已保存的说话人真实姓名写入实名版纪要，并补默认导出格式回退。
- `MeetingLibraryStore.swift` 新增选中纪要对应文件夹高亮、带二次确认的文件夹删除逻辑、说话人姓名临时映射文件，以及本地新增会议进度解析。
- `MainWindowView.swift` 补自动外观模式下的窗口外观同步；文件夹所在位置用灰色线框提示；删除文件夹可选择仅删除文件夹或连同纪要文件永久删除；标签芯片改为左对齐流式排布。
- `LaunchAgentManager.swift` 和 `BotRuntimeStore.swift` 修复“启动服务”误改变“开机启动”状态的问题。
- `AppPaths.swift`、`AppSettings.swift`、`EnvironmentHealth.swift` 合并 `.env` 解析入口为 `AppPaths.loadEnvValues()`。
- `SetupWizard.swift` 统一首次启动向导各步骤内容区高度和顶部对齐，避免翻页错位。
- 保留 `MeetingBotMenuBarAppApp.swift` 中当前主线的浅色状态栏图标设置，未采用备份中“跟随系统自动着色”的改动。
- 用户文档、安装文档、更新记录和分享清单已更新到 0.2.9；新增 `docs/后台待办_安装与会议生成.md` 记录后台脚本修复细节。

### 1. 飞书机器人交互优化

已增强 `bot.py` 中的飞书交互逻辑：

- 支持引用历史音频并回复“重新生成会议纪要”，默认复用已有转录结果。
- 支持引用历史音频并回复“重新转录”，强制重新下载并完整重跑 ASR。
- 支持上传或粘贴 `txt/md/markdown/csv/srt/vtt` 转录文字材料，跳过音频转写，直接生成纪要。
- 默认不在飞书对话框展开完整转录稿，只发送摘要和正式纪要文件。
- 增加重复材料复用逻辑：同一音频或文字已处理过时，跳过重复转写，仅重新汇编纪要和报告。
- 兼容历史 session：即使旧 session 没有 `source_metadata.json`，也会尝试用音频或文本 hash 匹配历史结果。
- 帮助文案已更新，明确说明可用命令和复用逻辑。

相关文件：

- `bot.py`
- `meetingbot_config.py`
- `report_export.py`

关键函数：

- `handle_text_message`
- `process_audio_message`
- `process_text_transcript_material`
- `find_reusable_session`
- `legacy_audio_source_matches`
- `legacy_text_source_matches`
- `generate_report_from_transcript`

### 2. 报告输出优化

已调整正式纪要文件生成逻辑：

- 去掉 DOCX、HTML、MD 顶部的 `Feishu Meeting Bot ...` 蓝色标识。
- DOCX 页脚保留页码字段：`第 PAGE / NUMPAGES 页`。
- HTML 打印样式增加页码规则。
- 修复 HTML 章节标题编号颜色问题：原先 `h2::first-letter` 只会让 `01` 中的 `0` 变蓝，现已改为使用 `.section-number` 包裹完整编号，因此 `01/02/...` 整体为蓝色。
- 已重生成已有 session 下的 HTML 文件，验证输出包含 `.section-number`。

相关文件：

- `report_export.py`
- `sessions/20260513_234841_a899b2/*.html` 已重生成过。

### 3. Python 代码拆分

原 `bot.py` 曾约 3467 行，维护成本较高。0.5.0 完成第二阶段拆分：

- `meetingbot_config.py`：集中配置、路径、模板常量。
- `report_export.py`：集中 DOCX、Markdown、HTML、PDF 导出逻辑。
- `feishu_io.py`：集中飞书凭据缓存、引用消息解析、流式下载、上传和回复。
- `audio_pipeline.py`：集中 ffmpeg 转换、模型按需加载、说话人分离、ASR 与进度回调。
- `runtime_status.py`：集中状态文件、完成事件和陈旧任务恢复的原子写入。
- `bot.py`：保留消息路由、会议业务编排、分类、纪要和导出协调逻辑。

当前行数大致为：

- `bot.py`：约 1660 行，当前主要保留消息路由和主流程编排。
- `report_export.py`：约 1186 行。
- `meetingbot_config.py`：约 61 行。
- `session_store.py`：集中 session 创建、复用、hash 和文本读取。
- `transcript_material.py`：集中上传文本规范化和文本段落解析。

后续拆分与任务调度计划统一记录在 `docs/DEVELOPMENT_ROADMAP.md`，不再在交接文档维护重复清单。

### 4. 菜单栏 App 优化

已优化 macOS 菜单栏 App：

- 服务/任务白色卡片缩小。
- “打开”区按钮更短，中文显示为“项目/会话/日志/错误”，仍指向原目录。
- “会议目录”保持在 PDF 按钮前。
- 增加“正在复用已有转录”的任务阶段显示。
- 底部增加“开机启动”复选框，并接入 `launchctl enable/disable`。
- “纪要完成后发送系统通知”保留。
- 缩小弹窗高度，从 640 调整为 560，并减少内容间距，减少底部空白。
- App 路径不再硬编码用户主目录；`0.2.5` 起后台支持目录改为 `~/Library/Application Support/meeting-bot`，日志目录改为 `~/Library/Logs/meeting-bot`，并把旧 `~/meetin-bot`、`~/meeting-bot`、`~/feishu-meeting-bot` 纳入升级迁移源。
- 左键单击状态栏图标恢复为打开轻量气泡弹窗，右键菜单提供“打开主界面”和“退出”。
- 新增“运行环境”简表，能看到 Python、`ffmpeg`、LibreOffice、Codex CLI 和核心配置是否就绪。
- 独立主界面的“概览”改为更充分利用宽屏空间的面板布局，不再复用弹窗视图。
- 新增“会议库”页：支持按内容搜索历史纪要、手工打标签、补充备注、人工标注说话人，并按主题/说话人查看跨 session 关联。
- 主界面“近期会议”可直接跳转到会议库详情。
- 主题关联从完全一致匹配升级为标签加近似标题匹配。
- 会议库把时间筛选收进和标签同排的弹层，可按单日或时间段过滤；日期弹层会高亮已有会议日期。
- 会议详情支持补充真实会议时间，和纪要生成时间分开保存；筛选与日历高亮优先使用真实会议时间。
- 主界面顶部右侧新增自动 / 白天 / 夜览循环切换，设置页切回跟随系统外观时会立即刷新全部窗口。
- 打开独立主界面时，App 会切换为普通应用模式并出现在 Dock；关闭主界面后回到仅状态栏模式。
- 轻量弹窗不再使用滚动容器，遇到异常时会按内容增高；运行状态区改为“状态/任务/环境”三栏，并可从右上角直接打开主界面。
- 设置页“运行状态”改为三项概览加独立更新时间，避免日期在右侧被挤成多行；设置窗口整体高度已收紧。
- 主界面顶部三块统一为同一色系，第二行两块统一为另一色系；当 `ffmpeg` 异常时，环境卡会显示一个图标化启动按钮。
- `ffmpeg` 健康检查已补 Homebrew 常见路径识别，避免 GUI App 因未继承终端 PATH 而误报缺失。
- 会议库空结果时改用固定结构滚动区，避免搜索框、统计行和滚动条跳动。
- 新增独立“设置”窗口中的四个主 tab：状态与服务、外观、高级设置、纪要设置；主界面顶部右侧也可直接打开设置。
- 主界面顶部改为更明确的自定义标签栏；会议库中的“新增会议”改为失焦时仍保持可见的固定样式按钮。
- 会议详情页的纪要类型现以中文显示，并可直接下拉切换模板；切换后会先询问是否重新生成纪要文件。
- 会议详情页的快速标签改为更紧凑的自适应排布，减少少量标签时的横向空档。
- 会议库支持从本地新增会议：可导入录音、转录稿，手动指定模板，并选择导出 HTML/DOCX/MD/PDF。
- 新增 `scripts/create_local_meeting.py`，本地新增会议复用既有 session、转写、纪要和事件写入流程。
- 新增 `report_generation.py` 中的公共会议分类能力，供重生成和本地新增会议共用。
- `LaunchAgentManager` 的启动和重启逻辑已补 `launchctl enable` 自恢复，避免服务曾被禁用后只报 `Bootstrap failed: 5`。
- 新增 `scripts/upgrade.sh` 与 `docs/UPGRADE_GUIDE.md`，并在打包时同步生成面向 `20260515_192856` 旧包的升级包。
- 安装与打包脚本现会保留并排除本地 `library/`，避免升级时覆盖用户标签、文件夹和自定义会议模板，也避免把本机资料带进分享包。
- 安装流程新增 `auto/reuse/offline/online` 四种依赖模式；`auto` 会自动复用现有环境、优先使用 `wheelhouse/`，再回退到在线安装。
- 新增 `scripts/preflight.sh`、`scripts/build_wheelhouse.sh` 与安装器 `preinstall` 检查，安装前会校验 macOS、芯片、内存、磁盘和 Python 条件。
- 新增首次启动配置向导 `SetupWizard.swift`：先做系统检查，再填写凭据，随后验证飞书、Hugging Face 和 Codex CLI，可用后直接启动服务。
- 旧独立更新包流程已从当前开发目录清理；默认升级路径改为覆盖安装新版拖拽式 App，并由 App 首次启动时自动刷新后台组件。
- 默认安装方式已改为拖拽式 DMG：用户将 `会议纪要助手.app` 拖入 `Applications`，首次打开后由 App 自动部署或升级 `~/Library/Application Support/meeting-bot`；若检测到旧 `~/meetin-bot`、`~/meeting-bot` 或 `~/feishu-meeting-bot`，会自动迁移用户数据并修正仍指向旧根目录的默认保存位置。
- 新增首次启动安装引导 `BootstrapInstaller.swift`：App 内嵌后台载荷，按载荷版本自动判断是否需要首次部署或升级，并把日志写入 `~/Library/Logs/meeting-bot/首次启动安装.log`。
- 默认分发物为 `会议纪要助手 0.2.11 安装盘.dmg`：其中只包含 `会议纪要助手.app`、`Applications` 快捷入口、`安装与升级说明.html` 和 `使用说明.html`。
- 二合一安装器新增持久安装日志和桌面失败说明文件；升级场景若现有 `.venv` 可用，会跳过对系统 Python 的重复硬检查，避免 root 安装环境 PATH 过窄导致误判。
- 芯片识别不再只依赖 `uname -m`，还会读取 `hw.optional.arm64`，避免 Apple Silicon 机器在兼容执行环境中被误判为 Intel。
- `meetingbot_config.py` 现在会把 `ffmpeg` 和 Codex CLI 解析为实际可执行路径，避免从 Finder 启动时只拿到裸命令。
- 新增会议失败不再把 stderr 写进所有历史纪要详情；本地会议页只展示精简后的当前错误。
- 文本转录解析新增保留字段过滤，避免把“生成时间”“会议类型”等纪要元数据误识别为说话人。
- 安装盘生成时会同步产出 `线程交接汇总`，便于下一轮开发接续。
- `0.2.6` 修复了旧 `.env` 缺少可选保存位置键时覆盖安装在迁移阶段提前中止的问题，并把安装失败提示改为显示退出码和最近进度。
- `0.2.7` 继续修复覆盖安装链路：旧日志迁移失败时不再阻断升级，迁移改用成功标记避免中断后漏迁剩余数据，已无需迁移时不会再误退，安装窗口会补读末尾输出，菜单栏图标也恢复为跟随系统明暗自动着色。
- `0.2.8` 收束主界面和会议库体验：升级成功后稳定留驻并打开主界面，更新准备窗口固定尺寸并改为内部滚动以规避布局崩溃，外观同步修正，新增会议语法错误修复，新增未分类文件夹、文件夹多选合并与纪要拖拽归档，设置和标签编辑区同步补齐。
- `0.2.9` 合并备份中的安装和会议库修复：安装可复用历史虚拟环境，本地新增会议显示实时进度，重生成模板会带入说话人实名，文件夹删除增加二次确认，自动外观和首次启动向导布局继续修正。
- `0.2.10` 修正自动外观下标题栏与主界面颜色冲突，设置页新增状态栏图标方案和颜色设置，新增会议完成后自动关闭窗口并可按选择打开导出文件。
- `0.2.11` 修正状态栏图标颜色实际渲染，图标方案设置改为可视化按钮，会议类型列表和设置页分区标题层级继续优化。

相关文件：

- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/AppPaths.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/BootstrapInstaller.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/MeetingBotMenuBarAppApp.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/MeetingBotMenuView.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/BotRuntimeStore.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/LaunchAgentManager.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/Models.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/EnvironmentHealth.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/MeetingLibraryStore.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/MainWindowView.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/SetupWizard.swift`
- `scripts/preflight.sh`
- `scripts/build_wheelhouse.sh`
- `scripts/build_setup_package.sh`
- `scripts/create_local_meeting.py`
- `report_generation.py`

注意事项：

- `/Applications/会议纪要助手.app` 曾经还是旧版，最新版构建位于 `dist/会议纪要助手.app`。
- 沙盒环境无法直接覆盖 `/Applications`，后续如果需要实际替换安装，需要用户授权或手工复制。

### 5. 日志告警处理

日志中反复出现：

- `Class AVFFrameReceiver is implemented in both ...`
- `Class AVFAudioReceiver is implemented in both ...`
- `pkg_resources is deprecated`
- `resource_tracker ... leaked semaphore`

本轮在 `start_bot.sh` 做了运行层处理：

- 使用 `PYTHONWARNINGS` 抑制部分 Python warning。
- 对 stderr 中的 AVF 重复类告警做过滤，避免持续刷日志。

这不是从根本上解决动态库冲突，只是减少日志噪声。根因大概率是 `av` wheel 内置 ffmpeg 动态库和 Homebrew ffmpeg 同时被加载。后续如果出现真实崩溃，应继续从 Python 包版本、`av`、`torchcodec`、Homebrew ffmpeg 链接关系排查。

相关文件：

- `start_bot.sh`

### 6. 依赖清单和安装文档

新增依赖清单和文档：

- `requirements.txt`
- `docs/DEPENDENCIES.md`
- `.env.example`
- `docs/SOFTWARE_GUIDE.html`
- `docs/SOFTWARE_GUIDE.md`
- `docs/INSTALLATION_GUIDE.md`
- `docs/SHARE_CHECKLIST.md`
- `tests/test_session_store.py`
- `tests/test_transcript_material.py`
- `tests/test_report_export.py`

文档覆盖：

- 软件用途和核心能力。
- 面向普通使用者的 HTML 软件说明页。
- 软件界面与主要按钮说明。
- 飞书机器人使用方式。
- macOS 菜单栏 App 功能。
- 本地目录说明。
- 新环境依赖准备。
- 飞书开放平台配置步骤。
- Hugging Face Token 配置。
- 半自动安装流程。
- 启动、查看日志、卸载、常见问题。
- 基础回归测试入口。
- 对外分享时应提供和禁止提供的材料。

### 7. 拖拽式安装和发行打包

当前保留脚本：

- `scripts/install.sh`
- `scripts/build_setup_package.sh`
- `scripts/doctor.sh`
- `MeetingBotMenuBarApp/build_release_app.sh`

`scripts/install.sh` 在新环境中执行：

- 将后台支持文件复制到 `$HOME/Library/Application Support/meeting-bot`。
- 创建 `.venv`。
- 安装 `requirements.txt`。
- 生成 `.env` 模板。
- 创建运行目录。
- 构建或安装菜单栏 App。
- 写入 `$HOME/Library/LaunchAgents/com.pgui.feishu-meeting-bot.plist`。
- 支持 `--no-start`、`--install-dir`、`--skip-app-build`。
- 若 `.env` 仍是占位配置，则跳过自动启动，避免在未完成配置时触发无效 bootstrap。
- `scripts/doctor.sh` 可集中检查 Python、`ffmpeg`、LibreOffice、Codex CLI、`.env` 和 LaunchAgent。

安装脚本不会自动填写：

- `FEISHU_APP_ID`
- `FEISHU_APP_SECRET`
- `HF_TOKEN`
- Codex CLI 登录状态。

`MeetingBotMenuBarApp/build_release_app.sh` 会生成内嵌后台载荷的 `dist/会议纪要助手.app`。
`scripts/build_setup_package.sh` 会在 App 构建完成后生成拖拽式安装盘，并同步输出线程交接汇总。

构建载荷会排除：

- `.env`
- `.venv`
- `sessions/`
- `downloads/`
- `logs/`
- `runtime/`
- `library/`
- `backups/`
- `latest_session.txt`
- `*.bak`
- `bot_backup_*.py`

包内包含：

- Python 后台代码。
- Swift 菜单栏 App 源码。
- 已构建的 `dist/会议纪要助手.app`。
- `.env.example`。
- `requirements.txt`。
- 软件说明、安装说明、依赖说明和分享清单。
- 安装脚本和拖拽式安装盘构建脚本。

## 当前重要文件清单

### 后台服务

- `bot.py`
- `meetingbot_config.py`
- `report_export.py`
- `start_bot.sh`
- `requirements.txt`
- `.env.example`
- `schemas/meeting_classification.schema.json`
- `schemas/meeting_report.schema.json`

### 菜单栏 App

- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/AppPaths.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/MeetingBotMenuBarAppApp.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/MeetingBotMenuView.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/BotRuntimeStore.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/LaunchAgentManager.swift`
- `MeetingBotMenuBarApp/MeetingBotMenuBarApp/Models.swift`
- `MeetingBotMenuBarApp/build_release_app.sh`

### 文档和安装

- `docs/SOFTWARE_GUIDE.html`
- `docs/SOFTWARE_GUIDE.md`
- `docs/INSTALLATION_GUIDE.md`
- `docs/SHARE_CHECKLIST.md`
- `docs/DEPENDENCIES.md`
- `docs/后台待办_安装与会议生成.md`
- `docs/DEVELOPMENT_ROADMAP.md`
- `scripts/install.sh`
- `scripts/build_setup_package.sh`

### 打包产物

- `dist/会议纪要助手.app`
- `dist/会议纪要助手卸载器.app`
- 默认安装盘路径：`dist/会议纪要助手 0.7.2 安装盘.dmg`
- 默认线程交接导出路径：`dist/线程交接汇总 0.7.2.md`
- 发布元数据路径：`dist/release-manifest-0.7.2.json`

## 已执行验证

2026-07-31 / 0.7.2 封版候选执行以下检查：

```bash
"$HOME/Library/Application Support/meeting-bot/.venv/bin/python" -m pytest --version
"$HOME/Library/Application Support/meeting-bot/.venv/bin/python" -m pytest tests -q
bash -n scripts/install.sh scripts/build_setup_package.sh scripts/build_wheelhouse.sh scripts/doctor.sh scripts/install_optional_tools.sh scripts/preflight.sh scripts/upgrade.sh start_bot.sh
PYTHON_BIN="$HOME/Library/Application Support/meeting-bot/.venv/bin/python" ENV_FILE=/tmp/meeting-bot-missing-env-for-preflight bash scripts/preflight.sh
"$HOME/Library/Application Support/meeting-bot/.venv/bin/python" -m py_compile scripts/create_local_meeting.py scripts/regenerate_session.py scripts/export_session_file.py scripts/generate_release_manifest.py scripts/data_recovery.py scripts/task_control.py bot.py feishu_io.py audio_pipeline.py runtime_status.py durable_storage.py task_ledger.py task_runtime.py asr_runtime.py diarization_runtime.py transcription_progress.py llm_backend.py speaker_naming.py meetingbot_config.py report_export.py report_generation.py session_store.py transcript_material.py
bash MeetingBotMenuBarApp/build_release_app.sh
bash MeetingBotUninstaller/build_uninstaller_app.sh
'dist/会议纪要助手卸载器.app/Contents/MacOS/MeetingBotUninstaller' --self-test
'dist/会议纪要助手卸载器.app/Contents/MacOS/MeetingBotUninstaller' --audit-scan
bash 'dist/会议纪要助手.app/Contents/Resources/bootstrap/meeting-bot/scripts/install.sh' --verify-payload-only
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' 'dist/会议纪要助手.app/Contents/Info.plist'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' 'dist/会议纪要助手.app/Contents/Info.plist'
file 'dist/会议纪要助手.app/Contents/MacOS/FeishuMeetingBot'
codesign --verify --deep --strict --verbose=2 'dist/会议纪要助手.app'
```

验证结果：

- pytest 已安装并可用，版本为 `9.1.0`。
- 测试结果：`114 passed`。
- Shell 脚本语法检查通过。
- 安装前检查全部通过；`sysctl` 受限时会使用 `hostinfo` 读取物理内存，非 Homebrew Codex CLI 及失效旧路径回退验证通过。
- Python 编译检查通过。
- 菜单栏 App 和卸载器已重新构建，`Info.plist` 版本均为 `0.7.2`，构建号均为 `38`。
- App 可执行文件为 `Mach-O 64-bit executable arm64`。
- `codesign --verify --deep --strict` 通过。
- App 内嵌载荷路径为 `Contents/Resources/bootstrap/meeting-bot`，未生成旧 `bootstrap/feishu-meeting-bot`。
- App 内载荷原样校验通过；自动化测试确认任一受清单保护文件被修改时校验失败。
- 卸载器临时目录自检通过；实际无副作用扫描未把 `/Users/Peng/Developer/meeting-bot` 或 `/Users/Peng/Developer/meeting-bot-1.0-native` 列为卸载对象。
- 内部测试安装盘只读挂载检查通过，根目录同时包含主 App、图形化卸载器、Applications 快捷入口和说明文档。
- 隔离升级失败演练命中 `after-project-copy` 测试节点并以退出码 `97` 中止；旧运行组件自动恢复，`.env`、会议资料和无关文件逐项比对未改变。
- `scripts/build_setup_package.sh` 默认版本号已同步到 `0.7.2`；当前已验证开发版 App 构建与签名完整性，正式 DMG 仍需真实发布签名和 Apple 公证凭据。
- 隔离的合成转录稿和两位合成说话人录音均完成端到端处理；录音任务生成两个 speaker ID，虚构实名修改后转录、纪要和 HTML/Markdown 同步更新。
- 飞书官方鉴权接口通过；未向真实会话发送消息。详细证据与正式发布阻断项见`docs/RELEASE_0.7_VERIFICATION.md`。
- `0.7.2 build 38` 开发候选已覆盖安装并重启；安装标记与 App 版本一致，LaunchAgent 运行、后台空闲，已安装目录自检全部通过。

## 备份目录

每次重要修改前均做过备份。相关备份目录：

- `backups/20260514_optimization/`
- `backups/20260514_startup_toggle/`
- `backups/20260514_ui_deps_refactor/`
- `backups/20260514_docs_installer/`
- `backups/20260515_docs_refresh/`

## 当前已知问题和风险

### 1. LaunchAgent 状态曾出现不一致

曾观察到：

- `runtime/status.json` 显示 service running。
- 日志显示后台在 `2026-05-14 16:16:30` 连接飞书成功。
- 但 `launchctl print gui/501/com.pgui.feishu-meeting-bot` 一度返回找不到 service。

后续需要在真实 macOS 会话中检查：

```bash
launchctl print gui/$(id -u)/com.pgui.feishu-meeting-bot
launchctl print-disabled gui/$(id -u) | rg com.pgui.feishu-meeting-bot
tail -f logs/bot_stdout.log
tail -f logs/bot_stderr.log
cat runtime/status.json
```

### 2. `/Applications` 中的 App 可能不是最新

由于沙盒权限限制，无法稳定覆盖安装：

`/Applications/会议纪要助手.app`

当前最新版在：

`dist/会议纪要助手.app`

若用户实际使用 `/Applications` 中的旧 App，可能看不到最新 UI 和开机启动选框。后续需要安装新版 App：

```bash
ditto "$HOME/Library/Application Support/meeting-bot/dist/会议纪要助手.app" "/Applications/会议纪要助手.app"
```

必要时让用户手动复制。

### 3. ffmpeg/av 重复动态库告警只是过滤日志

`start_bot.sh` 现在过滤了相关告警，但没有根治动态库加载冲突。如果后续发生音频处理崩溃，应继续排查 Python `av`、Homebrew ffmpeg、torchcodec/pyannote 之间的依赖关系。

### 4. 本机凭据仍需避免外泄

0.4.0 起 App 会把飞书 App Secret、Hugging Face Token 和 LLM API Key 保存到 macOS 系统钥匙串；旧版 `.env` 继续兼容，当前开发工作区仍可能含真实配置。发行包不会包含 `.env`，任何后续展示、提交或分享仍必须避免泄露配置与钥匙串内容。

### 5. 安装脚本依赖网络

`scripts/install.sh` 会执行 pip 安装依赖。新环境需要能访问 PyPI/Hugging Face 等外部服务；如果网络受限，需要改为离线 wheelhouse 安装。

## 建议后续开发任务

当前只执行 `docs/RELEASE_0.7_CLOSURE_PLAN.md`。0.7 是最后一个 Python 架构版本；原计划的 0.8、0.9 不再在当前代码上继续，相关进程隔离、资源治理、安装升级和发布要求迁入 1.0 原生重构。

1.0 的独立工作区为 `/Users/Peng/Developer/meeting-bot-1.0-native`。该目录与当前 `/Users/Peng/Developer/meeting-bot` 分离，但仍属于同一产品线。1.0 在 M0 架构验证、设计原型和三方评审通过前只允许编写文档与 PoC，不开始正式功能实现，也不得直接读写 0.7 用户资料。

0.7 封版完成后，应以最终 0.7 标签作为迁移合同基线；后续高严重性修复留在维护分支，再按需要选择性移植到 1.0，不把两个目录混用为同一运行环境。

Developer ID 签名、公证和 stapling 仍需真实 Apple Developer 凭据，是公开分发门槛，不应在无凭据环境中标记为已完成。

## 新线程建议切入点

如果新 agent 要继续开发，建议按以下顺序：

1. 阅读 `docs/SOFTWARE_GUIDE.md` 和 `docs/INSTALLATION_GUIDE.md`。
2. 阅读 `meetingbot_config.py`、`report_export.py`、`bot.py` 的主流程函数。
3. 运行静态检查：

```bash
.venv/bin/python -m py_compile bot.py report_export.py meetingbot_config.py
bash -n scripts/install.sh scripts/build_setup_package.sh start_bot.sh
```

4. 如涉及 App，先运行：

```bash
bash MeetingBotMenuBarApp/build_release_app.sh
```

5. 如涉及安装包，运行：

```bash
bash scripts/build_setup_package.sh
```

6. 不要把 `.env`、`sessions/`、`downloads/`、`logs/`、`runtime/`、`backups/` 放进发行包或外发内容。

## 2026-06-12 说话人、转写性能与会议库交互更新

- 会议库保存说话人姓名后，会写回 session 的 `speaker_map.json`，自动生成实名转录稿和会议纪要；清空姓名后恢复匿名版并移除陈旧实名文件。
- 显示层统一为 `SPEAKER_00 -> 说话人1`、`UNKNOWN -> 未知说话人`，旧值“说话人未知”按匿名值兼容处理。
- `diarization_runtime.py` 统一负责 pyannote 设备选择；Apple Silicon 优先使用 MPS，运行时不兼容则回退 CPU。真实 2 分钟片段测试约 10 秒完成。
- `transcription_progress.py` 按 faster-whisper 产出的时间戳写入实时百分比和已处理时长。
- `asr_runtime.py` 统一负责 faster-whisper；默认 `medium / CPU int8 / 16 threads / batch 8 / beam 5`。同一 2 分钟片段由 64.82 秒降至 29.81 秒，约 2.17 倍加速。
- 新增会议支持拖拽录音和转录稿；共享状态在窗口关闭后继续显示于主窗口底部，并可中止实际子进程。
- `scripts/create_local_meeting.py` 增加跨进程文件锁，阻止重复本地会议任务并行运行。
- 会议详情右侧标题、“撤销”和“保存”从滚动内容中拆出，改为固定顶部操作栏。
- 菜单栏在所有 `processing` 阶段基于当前所选 SF Symbol 播放动画，避免生成纪要阶段回退到带圈图标：`waveform` 使用可变层在 0.5 秒内由左向右单向推进，`waveform.path.ecg` 在推进时加入轻微上下跳动；随后暂停 1 秒再重复。
- 原始转录播放器拖动进度条时不再连续调用 `AVPlayer.seek`；拖动期间仅更新预览时间，松手后使用容差执行一次跳转，避免长录音频繁精确 seek 导致界面卡顿。
- App 构建载荷排除 `.git`；安装模式使用完整同步清理旧资源，避免 App 运行后产生 `.git` 记录并破坏签名。
- 验证：20 项 Python 单元测试通过；App 构建和 `codesign --verify --deep --strict` 通过。
