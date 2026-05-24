# Bugfix 分支说明（bugfix-xiong）

本分支修复了试运行过程中发现的两个 bug，并通过编译与测试验证。

## Bug 1：首次启动配置可用性检查时 Codex CLI 始终不通过

### 现象
首次启动配置向导（"首次启动配置" → 连通性检查）中，Codex CLI 一项始终显示失败，
但系统中确实安装了 Codex CLI，且 app 在实际生成报告时能够正常调用它。

### 根因
Codex CLI 是一个 `#!/usr/bin/env node` 脚本。当 app 由 Finder/launchd 启动时，
其继承的 `PATH` 是最小集合（`/usr/bin:/bin:/usr/sbin:/sbin`），**不包含**
Homebrew 的 `/opt/homebrew/bin`。因此执行 codex 时，shebang 中的 `env node`
找不到 node，进程以非 0 退出，检查判定为"未登录/校验失败"。

而真实生成报告时是通过 Python 环境调用，`PATH` 正常，所以能调用成功——这正是
"检查失败但实际能用"的原因。

此外，`EnvironmentHealth` 里原本虽设置了 PATH，但用了
`merging(...) { current, _ in current }`，在系统已存在 `PATH` 时会**保留稀疏的旧
PATH 并丢弃注入值**，存在同样隐患。

### 修复
- `SetupWizard.swift`：`checkCodex` 为子进程注入包含工具目录的 `PATH`
  （新增 `processEnvironmentWithToolPaths()`）。
- `EnvironmentHealth.swift`：`resolveExecutable` / `validateExecutable` 改用统一的
  `environmentWithToolPaths()`，将工具目录**前置**到已有 PATH，确保即使 PATH 已存在
  也能生效。

## Bug 2：退出 app 后后台服务仍常驻内存

### 现象
退出 app 前若未手动停止后台服务，退出 app 后后台服务仍继续运行，调用系统 Python
并占用大量内存。

### 根因
后台 bot 是通过 launchd 注册的 LaunchAgent（`com.pgui.feishu-meeting-bot`），
其 plist 配置了 `KeepAlive=true` 与 `RunAtLoad=true`，是一个独立于 app 的持久进程。
app 退出不会影响它；即使直接 kill 进程，launchd 也会因 `KeepAlive` 将其重新拉起。
真正停止它需要 `launchctl bootout`。app 此前没有任何终止回调来处理这件事。

### 修复
- `BotRuntimeStore.swift`：新增同步方法 `stopServiceOnTerminationIfNeeded()`，
  在退出时执行 `launchctl bootout` 停掉服务。
- `MeetingBotMenuBarAppApp.swift`：新增 `applicationWillTerminate(_:)`，退出时调用上述方法。

### 行为说明
为兼顾"登录时启动"这一守护模式：

- **未开启**"登录时启动" → 视为临时使用，退出 app 时停止后台服务。
- **已开启**"登录时启动" → 视为用户显式要求常驻后台，退出 app 时**保留**服务。

## 验证

- Swift：使用 `MeetingBotMenuBarApp/build_release_app.sh` 中相同的 `swiftc` 命令全量编译全部源文件，编译通过。
- Python：`pytest tests/` 7/7 通过（运行需提供占位环境变量
  `FEISHU_APP_ID` / `FEISHU_APP_SECRET` / `HF_TOKEN`）。

## 涉及文件

| 文件 | 改动 |
| --- | --- |
| `MeetingBotMenuBarApp/MeetingBotMenuBarApp/SetupWizard.swift` | Codex 检查注入 PATH |
| `MeetingBotMenuBarApp/MeetingBotMenuBarApp/EnvironmentHealth.swift` | 统一 PATH 构造并前置合并 |
| `MeetingBotMenuBarApp/MeetingBotMenuBarApp/BotRuntimeStore.swift` | 新增退出时停服务逻辑 |
| `MeetingBotMenuBarApp/MeetingBotMenuBarApp/MeetingBotMenuBarAppApp.swift` | 新增 `applicationWillTerminate` |

## 备注

Xcode 工程文件 `MeetingBotMenuBarApp.xcodeproj/project.pbxproj` 未引用
`BootstrapInstaller.swift`，因此直接用 Xcode 打开构建会报 `BootstrapInstallerStore`
找不到。实际发布构建依赖 `build_release_app.sh`（直接用 swiftc 编译全部源文件），不受影响。
如需用 Xcode 构建，需手动将该文件加入工程。
