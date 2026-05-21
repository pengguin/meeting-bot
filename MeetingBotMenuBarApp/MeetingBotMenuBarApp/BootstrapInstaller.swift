import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

final class BootstrapInstallerStore: ObservableObject {
    private enum PythonValidationError: LocalizedError {
        case notExecutable
        case unreadableVersion
        case unrecognizedVersion
        case unsupportedVersion(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .notExecutable:
                return "所选文件不可执行，请选择 Python 可执行文件。"
            case .unreadableVersion:
                return "无法读取所选 Python 的版本。"
            case .unrecognizedVersion:
                return "无法识别所选 Python 的版本。"
            case .unsupportedVersion(let version):
                return "所选 Python 为 \(version)，仍低于 3.12。"
            case .launchFailed(let message):
                return "无法执行所选 Python：\(message)"
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "正在准备本地组件"
    @Published private(set) var recentOutput: [String] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var requiresPythonAction = false
    @Published private(set) var pythonIssueSummary: String?
    @Published private(set) var selectedPythonPath: String?
    @Published private(set) var pythonSelectionMessage: String?
    @Published private(set) var dependencyMode = "auto"
    @Published private(set) var missingToolIDs = Set<String>()
    @Published private(set) var requiresToolAction = false
    @Published private(set) var isInstallingTools = false
    @Published private(set) var toolInstallMessage: String?

    private let fileManager = FileManager.default
    private var pendingCompletion: ((Bool) -> Void)?
    private(set) lazy var payloadVersion: String = {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("payload-version.txt"),
              let value = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return "unknown"
        }
        return value
    }()
    private(set) lazy var currentAssistantVersion: String = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }()

    var logFileURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/meeting-bot", isDirectory: true)
            .appendingPathComponent("首次启动安装.log")
    }

    var needsInstallation: Bool {
        let requiredFiles = [
            AppPaths.projectRoot.appendingPathComponent("bot.py"),
            AppPaths.projectRoot.appendingPathComponent("scripts/install.sh"),
            AppPaths.projectRoot.appendingPathComponent("start_bot.sh"),
        ]
        guard requiredFiles.allSatisfy(AppPaths.exists) else {
            return true
        }

        guard let installedVersion = try? String(
            contentsOf: AppPaths.installedPayloadVersionFile,
            encoding: .utf8
        )
        .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }

        return installedVersion != payloadVersion
    }

    var installedAssistantVersion: String? {
        for root in candidateInstallRoots {
            let versionURL = root
                .appendingPathComponent("runtime", isDirectory: true)
                .appendingPathComponent("installed_app_version.txt")
            if let value = try? String(
                contentsOf: versionURL,
                encoding: .utf8
            )
            .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        for root in candidateInstallRoots {
            let guideURL = root.appendingPathComponent("docs/SOFTWARE_GUIDE.md")
            guard let guide = try? String(contentsOf: guideURL, encoding: .utf8),
                  let firstLine = guide.split(separator: "\n").first else {
                continue
            }

            let text = String(firstLine)
            guard let versionRange = text.range(
                of: #"(\d+\.\d+(?:\.\d+)?)"#,
                options: .regularExpression
            ) else {
                continue
            }

            return String(text[versionRange])
        }
        return nil
    }

    var installationModeTitle: String {
        installedAssistantVersion == nil ? "首次启动安装" : "更新准备"
    }

    var versionSummary: String? {
        guard let installedAssistantVersion else {
            return nil
        }

        if installedAssistantVersion == currentAssistantVersion {
            return "检测到本机已安装版本 \(installedAssistantVersion)，将刷新本地运行组件。"
        }

        return "检测到本机已安装版本 \(installedAssistantVersion)，将更新到 \(currentAssistantVersion)。"
    }

    func start(completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            return
        }
        guard let payloadRoot = Bundle.main.resourceURL?
            .appendingPathComponent("bootstrap/meeting-bot", isDirectory: true),
              AppPaths.exists(payloadRoot.appendingPathComponent("scripts/install.sh")) else {
            errorMessage = "应用包中缺少本地组件载荷。请重新下载应用。"
            completion(false)
            return
        }

        prepareLogDirectory()
        pendingCompletion = completion
        isRunning = true
        errorMessage = nil
        requiresPythonAction = false
        pythonIssueSummary = nil
        statusText = installedAssistantVersion == nil
            ? "正在部署后台组件和运行环境"
            : "正在更新后台组件和运行环境"
        recentOutput = []

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        var arguments = [
            payloadRoot.appendingPathComponent("scripts/install.sh").path,
            "--install-dir",
            AppPaths.projectRoot.path,
            "--dependency-mode",
            dependencyMode,
            "--skip-app-build",
            "--skip-app-install",
        ]
        if let selectedPythonPath {
            arguments.append(contentsOf: ["--python-bin", selectedPythonPath])
        }
        if let legacyMigrationSource = AppPaths.legacyMigrationSource {
            arguments.append(contentsOf: ["--migrate-from", legacyMigrationSource.path])
        }
        process.arguments = arguments
        process.currentDirectoryURL = payloadRoot

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8) else {
                return
            }
            self?.appendOutput(output)
        }

        process.terminationHandler = { [weak self] process in
            let remainingData = pipe.fileHandleForReading.readDataToEndOfFile()
            if !remainingData.isEmpty,
               let remainingOutput = String(data: remainingData, encoding: .utf8) {
                self?.appendOutput(remainingOutput)
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }

                self.isRunning = false
                if process.terminationStatus == 0 {
                    self.markPayloadInstalled()
                    if self.missingToolIDs.isEmpty {
                        self.finishInstallation()
                    } else {
                        self.statusText = "基础安装已完成，仍有可自动补齐的工具"
                        self.requiresToolAction = true
                        self.errorMessage = nil
                    }
                } else {
                    self.statusText = self.failureStatusText
                    self.appendOutput("[bootstrap][失败] 安装脚本退出码 \(process.terminationStatus)\n")
                    self.errorMessage = self.installationFailureMessage(
                        exitCode: process.terminationStatus
                    )
                    completion(false)
                }
            }
        }

        do {
            try process.run()
        } catch {
            isRunning = false
            statusText = failureStatusText
            errorMessage = "无法启动安装流程：\(error.localizedDescription)"
            appendOutput("[bootstrap][失败] \(error.localizedDescription)\n")
            completion(false)
        }
    }

    func openLog() {
        FileOpener.open(logFileURL)
    }

    func useManagedOnlinePython() {
        dependencyMode = "managed-online"
        selectedPythonPath = nil
        pythonSelectionMessage = "将自动下载独立 Python 3.12 运行时，并在项目目录创建专用虚拟环境。"
    }

    func chooseOfflinePythonInstaller() {
        dependencyMode = "auto"
        let panel = NSOpenPanel()
        panel.title = "选择离线 Python 安装包"
        panel.message = "选择本地已有的 Python 3.12 或更高版本 `.pkg` 安装包。"
        if let pkgType = UTType(filenameExtension: "pkg") {
            panel.allowedContentTypes = [pkgType]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        FileOpener.open(url)
        pythonSelectionMessage = "安装离线 Python 包后，返回这里点击“重新尝试”。"
    }

    func chooseExistingPython() {
        dependencyMode = "auto"
        let panel = NSOpenPanel()
        panel.title = "选择已有 Python"
        panel.message = "可以选择系统 Python，也可以选择现有虚拟环境中的 `bin/python`。"
        panel.directoryURL = fileManager.homeDirectoryForCurrentUser
        panel.showsHiddenFiles = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        switch validatePython(at: url) {
        case .success(let version):
            dependencyMode = "auto"
            selectedPythonPath = url.path
            pythonSelectionMessage = "已选择 Python \(version)。点击“使用该 Python 重试”继续安装。"
        case .failure(let error):
            selectedPythonPath = nil
            pythonSelectionMessage = error.localizedDescription
        }
    }

    func installMissingTools() {
        guard !missingToolIDs.isEmpty, !isInstallingTools else {
            return
        }
        guard let payloadRoot = Bundle.main.resourceURL?
            .appendingPathComponent("bootstrap/meeting-bot", isDirectory: true) else {
            toolInstallMessage = "应用包中缺少工具安装脚本。"
            return
        }

        let scriptURL = payloadRoot.appendingPathComponent("scripts/install_optional_tools.sh")
        guard AppPaths.exists(scriptURL) else {
            toolInstallMessage = "应用包中缺少工具安装脚本。"
            return
        }

        isInstallingTools = true
        toolInstallMessage = nil
        statusText = "正在安装缺失工具"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path] + toolInstallArguments
        process.currentDirectoryURL = payloadRoot

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let output = String(data: data, encoding: .utf8) else {
                return
            }
            self?.appendOutput(output)
        }

        process.terminationHandler = { [weak self] process in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.isInstallingTools = false
                if process.terminationStatus == 0 {
                    self.toolInstallMessage = self.missingToolIDs.contains("codex")
                        ? "工具已安装。Codex CLI 仍需由你本人完成登录。"
                        : "工具已安装。"
                    self.finishInstallation()
                } else {
                    self.statusText = "工具自动安装未完成"
                    self.toolInstallMessage = "自动安装失败。可查看日志后重试，或暂时跳过。"
                }
            }
        }

        do {
            try process.run()
        } catch {
            isInstallingTools = false
            statusText = "工具自动安装未完成"
            toolInstallMessage = "无法启动工具安装流程：\(error.localizedDescription)"
        }
    }

    func continueWithoutOptionalTools() {
        finishInstallation()
    }

    private func prepareLogDirectory() {
        try? fileManager.createDirectory(
            at: logFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: logFileURL.path) {
            fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
    }

    private var candidateInstallRoots: [URL] {
        [AppPaths.projectRoot] + AppPaths.legacyInstallRoots
    }

    private func appendOutput(_ output: String) {
        guard !output.isEmpty else {
            return
        }

        try? append(output, to: logFileURL)

        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            recentOutput.append(contentsOf: lines)
            if recentOutput.count > 8 {
                recentOutput.removeFirst(recentOutput.count - 8)
            }
            if let pythonLine = lines.first(where: Self.isPythonIssueLine) {
                requiresPythonAction = true
                pythonIssueSummary = pythonLine
            }
            missingToolIDs.formUnion(lines.compactMap(Self.missingToolID))
        }
    }

    private func installationFailureMessage(exitCode: Int32) -> String {
        let latestDetail = recentOutput
            .reversed()
            .first(where: {
                let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return !line.isEmpty && !line.hasPrefix("[bootstrap]")
            })

        if let latestDetail {
            return "安装未完成（退出码 \(exitCode)）。最近信息：\(latestDetail)"
        }
        return "安装未完成（退出码 \(exitCode)）。请打开安装日志查看详情后重试。"
    }

    private func append(_ text: String, to url: URL) throws {
        if let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            if let data = text.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func markPayloadInstalled() {
        try? fileManager.createDirectory(
            at: AppPaths.runtimeDirectory,
            withIntermediateDirectories: true
        )
        try? payloadVersion
            .appending("\n")
            .write(to: AppPaths.installedPayloadVersionFile, atomically: true, encoding: .utf8)
        try? currentAssistantVersion
            .appending("\n")
            .write(to: AppPaths.installedAppVersionFile, atomically: true, encoding: .utf8)
    }

    private func finishInstallation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.statusText = self.installedAssistantVersion == nil ? "首次启动安装已完成" : "更新准备已完成"
            self.requiresToolAction = false
            let completion = self.pendingCompletion
            self.pendingCompletion = nil
            completion?(true)
        }
    }

    private var failureStatusText: String {
        installedAssistantVersion == nil ? "首次启动安装失败" : "更新准备失败"
    }

    private var toolInstallArguments: [String] {
        [
            missingToolIDs.contains("ffmpeg") ? "--ffmpeg" : nil,
            missingToolIDs.contains("libreoffice") ? "--libreoffice" : nil,
            missingToolIDs.contains("codex") ? "--codex" : nil,
        ]
        .compactMap { $0 }
    }

    private func validatePython(at url: URL) -> Result<String, PythonValidationError> {
        guard fileManager.isExecutableFile(atPath: url.path) else {
            return .failure(.notExecutable)
        }

        let process = Process()
        process.executableURL = url
        process.arguments = [
            "-c",
            "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return .failure(.unreadableVersion)
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let version = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parts = version.split(separator: ".").compactMap { Int($0) }
            guard parts.count >= 2 else {
                return .failure(.unrecognizedVersion)
            }
            guard parts[0] > 3 || (parts[0] == 3 && parts[1] >= 12) else {
                return .failure(.unsupportedVersion(version))
            }
            return .success(version)
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
    }

    private static func isPythonIssueLine(_ line: String) -> Bool {
        line.contains("Python")
            && (
                line.contains("需要 Python 3.12")
                    || line.contains("未找到 Python 3.12")
                    || line.contains("指定的 Python")
            )
    }

    private static func missingToolID(from line: String) -> String? {
        if line.contains("ffmpeg 未找到") {
            return "ffmpeg"
        }
        if line.contains("LibreOffice 未找到") || line.contains("soffice") && line.contains("未找到") {
            return "libreoffice"
        }
        if line.contains("Codex CLI 未找到") || line.contains("codex") && line.contains("未找到") {
            return "codex"
        }
        return nil
    }
}

struct BootstrapInstallWindowView: View {
    @ObservedObject var store: BootstrapInstallerStore
    @AppStorage("preferredMainColorScheme") private var preferredMainColorScheme = "system"
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(store.installationModeTitle)
                    .font(.title2.weight(.semibold))

                Text(store.statusText)
                    .foregroundStyle(.secondary)

                if let versionSummary = store.versionSummary {
                    Text(versionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if store.isRunning {
                    ProgressView()
                        .progressViewStyle(.linear)
                }

                GroupBox("当前进度") {
                    VStack(alignment: .leading, spacing: 6) {
                        if store.recentOutput.isEmpty {
                            Text("等待安装流程开始。")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(store.recentOutput.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.caption)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage = store.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                if store.requiresPythonAction {
                    GroupBox("Python 处理方式") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(store.pythonIssueSummary ?? "当前机器还没有可用的 Python 3.12 或更高版本。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("自动在线安装") {
                                    store.useManagedOnlinePython()
                                    retry()
                                }
                                Button("选择已有 Python") {
                                    store.chooseExistingPython()
                                }
                                Button("打开离线安装包") {
                                    store.chooseOfflinePythonInstaller()
                                }
                            }

                            Text("如果你已经有 Python 3.12+，也可以直接选择虚拟环境中的 `bin/python`。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let selectedPythonPath = store.selectedPythonPath {
                                Text(selectedPythonPath)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                Button("使用该 Python 重试") {
                                    retry()
                                }
                            }

                            if let pythonSelectionMessage = store.pythonSelectionMessage {
                                Text(pythonSelectionMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if store.requiresToolAction {
                    GroupBox("可自动补齐的工具") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(toolSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack {
                                Button("自动安装缺失工具") {
                                    store.installMissingTools()
                                }
                                .disabled(store.isInstallingTools)

                                Button("暂时跳过") {
                                    store.continueWithoutOptionalTools()
                                }
                                .disabled(store.isInstallingTools)
                            }

                            if store.isInstallingTools {
                                ProgressView()
                                    .progressViewStyle(.linear)
                            }

                            Text("会使用 Homebrew 安装 ffmpeg 和 LibreOffice，并安装 Codex CLI；若机器尚无 Homebrew，安装过程会先准备它。Codex CLI 安装后仍需登录。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let toolInstallMessage = store.toolInstallMessage {
                                Text(toolInstallMessage)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack {
                    Button("打开安装日志") {
                        store.openLog()
                    }
                    Spacer()
                    if !store.isRunning, store.errorMessage != nil {
                        Button("重新尝试") {
                            retry()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .frame(width: 680, height: 476)
        .preferredColorScheme(AppAppearance.resolvedColorScheme(for: preferredMainColorScheme))
    }

    private var toolSummary: String {
        let names = store.missingToolIDs.sorted().map { id in
            switch id {
            case "ffmpeg":
                return "ffmpeg"
            case "libreoffice":
                return "LibreOffice"
            case "codex":
                return "Codex CLI"
            default:
                return id
            }
        }
        return "检测到缺失：\(names.joined(separator: "、"))。"
    }
}
