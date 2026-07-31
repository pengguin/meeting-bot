# 0.7.2 封版验证记录

验证日期：2026-07-31
候选版本：`0.7.2 build 38`
状态：本机工程与合成真实任务通过；正式发布门槛仍有外部阻断项

## 自动化与静态检查

- Python：`114 passed`，7 个第三方弃用警告，无测试失败。
- Python `compileall`：通过。
- 安装、升级、诊断、打包和启动 Shell 脚本语法：通过。
- 安装前检查：macOS、Apple Silicon、128GB 内存、磁盘、Python 3.12、ffmpeg、LibreOffice 和已登录 Codex CLI 全部识别通过。
- 非 Homebrew 工具发现：覆盖 `~/.local/bin`、nvm、npm/npx、pnpm、Volta、Bun、Homebrew 和登录 Shell；失效的旧 `CODEX_BIN` 会回退搜索。

## App、卸载器与安装盘

- 主 App 和卸载器均为 arm64，版本和 build 一致。
- 开发候选使用 ad-hoc 签名，`codesign --verify --deep --strict` 通过。
- 内嵌载荷清单验证通过，未包含 `.env`、Token、用户会议目录或真实资料。
- 卸载器 `--self-test` 与 `--audit-scan` 通过，未把源码仓库或 1.0 工作区列为删除目标。
- 安装事务故障注入确认旧运行组件、`.env`、会议资料和无关文件在失败后恢复。
- DMG 文件系统校验、artifact SHA-256 和发布清单一致性通过。当前构建的权威文件大小和 SHA-256 记录在 `dist/release-manifest-0.7.2.json`，避免将安装盘哈希写回安装盘内文档而形成循环依赖。
- 开发候选已覆盖安装到 `/Applications` 并重启；安装标记显示 `0.7.2`，新载荷版本已登记，App 进程和 LaunchAgent 均运行，后台状态为 `idle`。
- 已安装目录执行 `doctor.sh` 全部通过，包括虚拟环境、ffmpeg、非 Homebrew Codex CLI、LibreOffice 和三项必要配置。

当前发布清单只对应 ad-hoc 开发候选。正式 Developer ID 签名和公证会改变安装盘内容，公开 Release 必须重新生成发布清单。

## 合成真实任务

所有测试材料均由本轮生成，不含用户会议正文、真实姓名或用户文件路径。

### 转录稿入口

- 输入：五段虚构中文会议转录。
- 完成：创建临时会议、导入、结构化纪要、HTML 和 Markdown 导出。
- 验证：`local_meeting_state` 文档类型正确，统一任务账本状态为 `completed/completed`，报告必填字段齐全。

该测试首次发现运行状态写入草稿时的 document type 冲突；修复后新增回归测试并重跑通过。故障遗留任务经启动审计转为 `paused`，没有被误标为完成。

### 录音入口

- 输入：macOS 系统生成的两位虚构说话人、20.48 秒中文 M4A。
- 完成：音频标准化、MPS 说话人分离、ASR、对齐、Codex 纪要、HTML 和 Markdown 导出。
- 验证：生成 7 个对齐 segment，识别 `SPEAKER_00` 与 `SPEAKER_01`，统一任务账本完成。
- 实名更新：将两位说话人改为虚构姓名后，`speaker_map.json`、`transcript_named.md`、`report_named.json`、实名 HTML 和 Markdown 同步生成且包含一致姓名。

运行中观察到 PyAV 与 Homebrew ffmpeg 的 AVFoundation Objective-C 类重复警告，但本次任务未崩溃。0.7 将其记录为旧技术栈已知限制；1.0 原生音频架构不复用该组合。

## 飞书

- 使用现有 App ID/Secret 调用飞书官方 tenant access token 接口：通过。
- 后台 LaunchAgent：运行中。
- 未向任何真实会话发送测试消息，也未读取历史消息或附件。

## 尚未通过的正式发布门槛

1. 本机没有 Developer ID Application 签名身份，`security find-identity` 返回 0 个有效身份。
2. 未配置正式载荷签名私钥/公钥和 `notarytool` Keychain profile，无法完成 Hardened Runtime、公证、stapling 与 Gatekeeper 发布验证。
3. 尚未由用户指定飞书测试会话，因此真实消息、引用、文件回传、重新转录和重新生成纪要未验证。
4. 全新机器、0.6 升级、0.7 覆盖、断网、磁盘不足和权限不足的真实安装矩阵尚未全部执行；当前只有自动化与隔离故障注入证据。
5. 最终分支尚未合并到 `main`，不可变标签和 GitHub Release 尚未创建。

在以上五项完成前，文档不得把 0.7 写成“正式封版”，也不得公开分发当前 ad-hoc 签名安装盘。
