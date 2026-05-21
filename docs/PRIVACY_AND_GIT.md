# Git 与隐私保护清单

本文用于在把项目同步到 GitHub 前检查隐私和仓库边界。

## 不应入库

- `.env`、`.env.*`：真实密钥和本机配置。只保留 `.env.example`。
- `.venv/`：本地 Python 运行环境，体积大且不可移植。
- `sessions/`：会议录音、转录、报告 JSON、正式纪要和补导出文件。
- `downloads/`：飞书下载的原始会议材料。
- `runtime/`：运行状态、事件记录和本机安装标记。
- `library/`：本机会议库标签、文件夹、模板和用户元数据。
- `dist/`：安装盘、App、交接汇总等发布产物。
- `backups/`：历史备份，可能包含旧代码、旧配置样例和临时文档。
- `tmp/`、`__pycache__/`、`.pytest_cache/`、`.DS_Store`：缓存或临时文件。

## 可以入库

- Python 后台源码：`bot.py`、`meetingbot_config.py`、`report_export.py`、`report_generation.py`、`session_store.py`、`transcript_material.py`。
- macOS App 源码：`MeetingBotMenuBarApp/`。
- 脚本：`scripts/`。
- 文档：`docs/`。
- Schema：`schemas/`。
- 测试：`tests/`。
- 配置样例：`.env.example`。
- 项目说明：`README.md`、`requirements.txt`、`start_bot.sh`。

## 提交前检查

```bash
git status --short
git diff --cached --name-only
git grep -n "FEISHU_APP_SECRET\\|HF_TOKEN\\|OPENAI_API_KEY\\|sk-" -- .
```

如果还没有提交，可以先查看将会被纳入版本库的文件：

```bash
git add --dry-run .
```

## GitHub 建议

- 仓库先设为 private。
- 使用分支和 Pull Request 协作。
- 不在 issue、PR、commit message 中粘贴密钥、会议原文、录音文件名或参会人隐私信息。
- 发布文件通过 GitHub Releases 或本地渠道分发，不直接提交到普通源码目录。
