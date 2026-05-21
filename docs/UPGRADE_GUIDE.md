# 会议纪要助手 升级说明

## 适用范围

本说明适用于已经安装并运行过会议纪要助手的用户升级到当前 `0.2.14` 版本。

## 推荐方式：同一份安装盘

如果你不想区分“新装”还是“升级”，可直接使用默认分发物：

- `会议纪要助手 0.2.14 安装盘.dmg`

打开后将 `会议纪要助手.app` 拖入 `Applications` 覆盖旧版，再打开 App。它会自动判断这台电脑是否已有安装目录：

- 没有：走首次部署流程。
- 已有：先提示当前已安装版本，再走保留数据的升级流程。

## 升级前说明

- 升级会保留现有 `.env`、已配置的录音与纪要保存位置、`sessions/`、`downloads/`、`runtime/`、`library/`、独立日志目录和本地会议模板。
- 新版默认支持目录为 `$HOME/Library/Application Support/meeting-bot`，日志目录为 `$HOME/Library/Logs/meeting-bot`。
- 如果旧版仍位于 `$HOME/Library/Application Support/meetin-bot`、`$HOME/Library/Application Support/feishu-meeting-bot`、`$HOME/meetin-bot`、`$HOME/meeting-bot` 或 `$HOME/feishu-meeting-bot`，新版会自动迁移到新的标准目录；若 `.env` 中的默认保存位置仍指向旧根目录，也会同步改写。
- 升级会替换程序代码、菜单栏 App 和发布文档。
- 如果旧版本曾把后台服务禁用，`0.2.12` 版本会在“启动”或“重启”时先尝试恢复 LaunchAgent，再继续加载服务。
- 如果想先了解本次升级新增了什么，可先阅读 `docs/CHANGELOG.md`。

## 升级后检查

- 主界面和设置窗口可正常打开。
- 版本号显示为 `0.2.14`。
- 历史会议仍可在“会议库”中查看。
- 后台服务状态正常；如曾被禁用，点击“启动”后应能自行恢复。

若需要自检，可运行：

```bash
bash "$HOME/Library/Application Support/meeting-bot/scripts/doctor.sh"
```
