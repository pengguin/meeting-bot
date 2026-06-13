import AppKit
import Foundation
import SwiftUI

enum SetupCheckSeverity: Equatable {
    case passed
    case warning
    case failed

    var symbolName: String {
        switch self {
        case .passed:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .passed:
            return .green
        case .warning:
            return .orange
        case .failed:
            return .red
        }
    }
}

struct SetupCheckItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let severity: SetupCheckSeverity
}

enum SystemReadinessChecker {
    static func run() -> [SetupCheckItem] {
        [
            macOSCheck(),
            chipCheck(),
            memoryCheck(),
            diskCheck(),
        ]
    }

    private static func macOSCheck() -> SetupCheckItem {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let display = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let passed = version.majorVersion >= 14
        return SetupCheckItem(
            id: "macos",
            title: "macOS",
            detail: passed ? "当前版本 \(display)" : "当前版本 \(display)，需要 macOS 14 或更高版本",
            severity: passed ? .passed : .failed
        )
    }

    private static func chipCheck() -> SetupCheckItem {
        #if arch(arm64)
        return SetupCheckItem(
            id: "chip",
            title: "芯片",
            detail: "Apple Silicon",
            severity: .passed
        )
        #else
        return SetupCheckItem(
            id: "chip",
            title: "芯片",
            detail: "当前版本仅支持 Apple Silicon",
            severity: .failed
        )
        #endif
    }

    private static func memoryCheck() -> SetupCheckItem {
        let gigabytes = Int(ProcessInfo.processInfo.physicalMemory / 1024 / 1024 / 1024)
        if gigabytes < 8 {
            return SetupCheckItem(
                id: "memory",
                title: "内存",
                detail: "约 \(gigabytes)GB，至少需要 8GB",
                severity: .failed
            )
        }
        if gigabytes < 16 {
            return SetupCheckItem(
                id: "memory",
                title: "内存",
                detail: "约 \(gigabytes)GB，可运行；建议 16GB 或更高",
                severity: .warning
            )
        }
        return SetupCheckItem(
            id: "memory",
            title: "内存",
            detail: "约 \(gigabytes)GB",
            severity: .passed
        )
    }

    private static func diskCheck() -> SetupCheckItem {
        do {
            let values = try AppPaths.projectRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let freeBytes = values.volumeAvailableCapacityForImportantUsage ?? 0
            let gigabytes = Int(freeBytes / 1024 / 1024 / 1024)
            if gigabytes < 8 {
                return SetupCheckItem(
                    id: "disk",
                    title: "磁盘空间",
                    detail: "约 \(gigabytes)GB 可用，至少需要 8GB",
                    severity: .failed
                )
            }
            if gigabytes < 12 {
                return SetupCheckItem(
                    id: "disk",
                    title: "磁盘空间",
                    detail: "约 \(gigabytes)GB 可用；建议预留 12GB 或更高",
                    severity: .warning
                )
            }
            return SetupCheckItem(
                id: "disk",
                title: "磁盘空间",
                detail: "约 \(gigabytes)GB 可用",
                severity: .passed
            )
        } catch {
            return SetupCheckItem(
                id: "disk",
                title: "磁盘空间",
                detail: "无法读取剩余空间",
                severity: .warning
            )
        }
    }
}

enum ConnectivityCheckStatus {
    case idle
    case running
    case passed(String)
    case failed(String)

    var severity: SetupCheckSeverity {
        switch self {
        case .passed:
            return .passed
        case .failed:
            return .failed
        case .running, .idle:
            return .warning
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "尚未检查"
        case .running:
            return "检查中"
        case .passed(let detail), .failed(let detail):
            return detail
        }
    }
}

@MainActor
final class SetupWizardStore: ObservableObject {
    @Published private(set) var feishuStatus: ConnectivityCheckStatus = .idle
    @Published private(set) var huggingFaceStatus: ConnectivityCheckStatus = .idle
    @Published private(set) var llmStatus: ConnectivityCheckStatus = .idle
    @Published private(set) var isChecking = false

    func runConnectivityChecks(config: RuntimeConfigStore) {
        guard !isChecking else {
            return
        }

        isChecking = true
        feishuStatus = .running
        huggingFaceStatus = .running
        llmStatus = .running

        let provider = LLMProviderOption(rawValue: config.llmProvider) ?? .codex
        let codexBinary = config.codexBin
        let apiBase = config.llmApiBase
        let apiKey = config.llmApiKey
        let model = config.llmModel

        Task {
            async let feishu = Self.checkFeishu(
                appID: config.feishuAppID,
                appSecret: config.feishuAppSecret
            )
            async let huggingFace = Self.checkHuggingFace(token: config.hfToken)
            async let llm = Self.checkLLMBackend(
                provider: provider,
                codexBinary: codexBinary,
                apiBase: apiBase,
                apiKey: apiKey,
                model: model
            )

            feishuStatus = await feishu
            huggingFaceStatus = await huggingFace
            llmStatus = await llm
            isChecking = false
        }
    }

    var allPassed: Bool {
        [feishuStatus, huggingFaceStatus, llmStatus].allSatisfy {
            if case .passed = $0 {
                return true
            }
            return false
        }
    }

    private static func checkFeishu(appID: String, appSecret: String) async -> ConnectivityCheckStatus {
        guard !appID.isEmpty, !appSecret.isEmpty else {
            return .failed("请先填写飞书 App ID 和 App Secret")
        }

        guard let url = URL(string: "https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal/") else {
            return .failed("飞书地址无效")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "app_id": appID,
            "app_secret": appSecret,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return .failed("飞书接口不可达")
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (payload["code"] as? Int) == 0 else {
                return .failed("飞书凭据不可用")
            }
            return .passed("已成功获取 tenant access token")
        } catch {
            return .failed("飞书连接失败：\(error.localizedDescription)")
        }
    }

    private static func checkHuggingFace(token: String) async -> ConnectivityCheckStatus {
        guard !token.isEmpty else {
            return .failed("请先填写 Hugging Face Token")
        }
        guard let url = URL(string: "https://huggingface.co/api/models/pyannote/speaker-diarization-community-1") else {
            return .failed("Hugging Face 地址无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("未收到 Hugging Face 响应")
            }
            if httpResponse.statusCode == 200 {
                return .passed("Token 可用，模型可访问")
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .failed("Token 无效，或尚未接受模型条款")
            }
            return .failed("Hugging Face 返回 \(httpResponse.statusCode)")
        } catch {
            return .failed("Hugging Face 连接失败：\(error.localizedDescription)")
        }
    }

    private static func checkLLMBackend(
        provider: LLMProviderOption,
        codexBinary: String,
        apiBase: String,
        apiKey: String,
        model: String
    ) async -> ConnectivityCheckStatus {
        switch provider {
        case .codex:
            return await checkCodex(binary: codexBinary)
        case .anthropic:
            return await checkAnthropic(apiBase: apiBase, apiKey: apiKey)
        case .openai, .lmStudio, .ollama:
            return await checkOpenAICompatible(
                provider: provider,
                apiBase: apiBase,
                apiKey: apiKey,
                model: model
            )
        }
    }

    private nonisolated static func normalizedAPIBase(
        _ raw: String,
        provider: LLMProviderOption
    ) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty {
            base = provider.defaultAPIBase
        }
        while base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }

    private static func checkOpenAICompatible(
        provider: LLMProviderOption,
        apiBase: String,
        apiKey: String,
        model: String
    ) async -> ConnectivityCheckStatus {
        if provider == .openai, apiKey.isEmpty {
            return .failed("请先填写 API Key")
        }
        if provider == .openai, model.isEmpty {
            return .failed("请先填写模型名称")
        }

        let base = normalizedAPIBase(apiBase, provider: provider)
        guard let url = URL(string: "\(base)/models") else {
            return .failed("API 地址无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("未收到服务响应")
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .failed("API Key 无效（HTTP \(httpResponse.statusCode)）")
            }
            guard httpResponse.statusCode == 200 else {
                return .failed("服务返回 HTTP \(httpResponse.statusCode)")
            }

            if provider == .lmStudio || provider == .ollama {
                let items = ((try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any])?["data"] as? [[String: Any]]) ?? []
                if items.isEmpty {
                    return .failed("服务可达，但没有可用模型，请先在服务端加载模型")
                }
                if model.isEmpty, let first = items.first?["id"] as? String {
                    return .passed("服务可达，将自动使用模型：\(first)")
                }
            }
            return .passed("服务可达，配置有效")
        } catch {
            return .failed("无法连接：\(error.localizedDescription)")
        }
    }

    private static func checkAnthropic(
        apiBase: String,
        apiKey: String
    ) async -> ConnectivityCheckStatus {
        guard !apiKey.isEmpty else {
            return .failed("请先填写 API Key")
        }

        var base = normalizedAPIBase(apiBase, provider: .anthropic)
        if !base.hasSuffix("/v1") {
            base += "/v1"
        }
        guard let url = URL(string: "\(base)/models") else {
            return .failed("API 地址无效")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("未收到服务响应")
            }
            if httpResponse.statusCode == 200 {
                return .passed("API Key 有效")
            }
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                return .failed("API Key 无效")
            }
            return .failed("服务返回 HTTP \(httpResponse.statusCode)")
        } catch {
            return .failed("无法连接：\(error.localizedDescription)")
        }
    }

    private static func checkCodex(binary: String) async -> ConnectivityCheckStatus {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let launch = launchCommand(for: binary)
                process.executableURL = launch.executableURL
                process.arguments = launch.arguments
                process.environment = Self.processEnvironmentWithToolPaths()
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: .passed(output.isEmpty ? "Codex CLI 已登录" : output))
                    } else {
                        continuation.resume(returning: .failed(output.isEmpty ? "Codex CLI 尚未登录" : output))
                    }
                } catch {
                    continuation.resume(returning: .failed("Codex CLI 不可用：\(error.localizedDescription)"))
                }
            }
        }
    }

    private nonisolated static func processEnvironmentWithToolPaths() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let toolDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        var combined = toolDirectories
        for path in existing where !combined.contains(path) {
            combined.append(path)
        }
        environment["PATH"] = combined.joined(separator: ":")
        return environment
    }

    private nonisolated static func launchCommand(for binary: String) -> (executableURL: URL, arguments: [String]) {
        if binary.contains("/") {
            return (URL(fileURLWithPath: binary), ["login", "status"])
        }

        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let candidate = "\(directory)/\(binary)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return (URL(fileURLWithPath: candidate), ["login", "status"])
            }
        }

        return (URL(fileURLWithPath: "/usr/bin/env"), [binary, "login", "status"])
    }
}

private enum SetupWizardStep: Int, CaseIterable, Identifiable {
    case readiness
    case storage
    case credentials
    case connectivity

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .readiness:
            return "系统检查"
        case .storage:
            return "保存位置"
        case .credentials:
            return "填写配置"
        case .connectivity:
            return "可用性检查"
        }
    }
}

struct SetupWizardWindowView: View {
    @ObservedObject var runtimeStore: BotRuntimeStore
    @ObservedObject var configStore: RuntimeConfigStore
    @StateObject private var wizardStore = SetupWizardStore()
    @State private var currentStep: SetupWizardStep = .readiness
    @AppStorage("preferredMainColorScheme") private var preferredMainColorScheme = "system"
    let finish: () -> Void

    private var systemChecks: [SetupCheckItem] {
        SystemReadinessChecker.run()
    }

    private var environmentChecks: [SetupCheckItem] {
        runtimeStore.environmentChecks.map {
            SetupCheckItem(
                id: $0.id,
                title: $0.title,
                detail: $0.detail,
                severity: $0.isHealthy ? .passed : .warning
            )
        }
    }

    private var hasHardBlocker: Bool {
        systemChecks.contains { $0.severity == .failed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("首次启动配置")
                    .font(.title2.weight(.semibold))
                Text("先确认这台电脑能稳定运行，再确定保存位置、填写凭据并验证连通性。")
                    .foregroundStyle(.secondary)
            }

            Picker("步骤", selection: $currentStep) {
                ForEach(SetupWizardStep.allCases) { step in
                    Text(step.title).tag(step)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            GroupBox {
                switch currentStep {
                case .readiness:
                    readinessStep
                case .storage:
                    storageStep
                case .credentials:
                    credentialsStep
                case .connectivity:
                    connectivityStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                if currentStep.rawValue > 0 {
                    Button("上一步") {
                        currentStep = SetupWizardStep(rawValue: currentStep.rawValue - 1) ?? .readiness
                    }
                }

                Spacer()

                switch currentStep {
                case .readiness:
                    Button("下一步") {
                        currentStep = .storage
                    }
                    .disabled(hasHardBlocker)
                case .storage:
                    Button("保存并继续") {
                        configStore.save()
                        currentStep = .credentials
                    }
                case .credentials:
                    Button("保存并继续") {
                        configStore.save()
                        runtimeStore.refresh()
                        currentStep = .connectivity
                    }
                    .disabled(!configStore.isCoreConfigComplete)
                case .connectivity:
                    Button("运行检查") {
                        configStore.save()
                        runtimeStore.refresh()
                        wizardStore.runConnectivityChecks(config: configStore)
                    }
                    .disabled(wizardStore.isChecking || !configStore.isCoreConfigComplete)

                    Button("完成并启动服务") {
                        UserDefaults.standard.set(true, forKey: "setupWizardCompleted")
                        runtimeStore.startService()
                        finish()
                    }
                    .disabled(!wizardStore.allPassed)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 520)
        .preferredColorScheme(AppAppearance.resolvedColorScheme(for: preferredMainColorScheme))
    }

    private var readinessStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("先确认系统版本、硬件条件和基础工具是否满足要求；这些结果会影响后续安装与运行稳定性。")
                .foregroundStyle(.secondary)

            Text("安装前条件")
                .font(.headline)
            checkList(systemChecks)

            Divider()

            Text("运行环境")
                .font(.headline)
            checkList(environmentChecks)

            if hasHardBlocker {
                Text("存在硬性条件不满足，继续安装后仍可能无法运行。")
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedLLMProvider: LLMProviderOption {
        LLMProviderOption(rawValue: configStore.llmProvider) ?? .codex
    }

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("飞书 App ID", text: $configStore.feishuAppID)
            SensitiveTextField(placeholder: "飞书 App Secret", text: $configStore.feishuAppSecret)
            SensitiveTextField(placeholder: "Hugging Face Token", text: $configStore.hfToken)
            Divider()

            Picker("纪要生成后端", selection: $configStore.llmProvider) {
                ForEach(LLMProviderOption.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.menu)
            Text(selectedLLMProvider.configHint)
                .font(.caption)
                .foregroundStyle(.secondary)

            if selectedLLMProvider == .codex {
                TextField("Codex 可执行文件", text: $configStore.codexBin)
            } else {
                TextField(
                    "LLM API 地址（留空使用 \(selectedLLMProvider.defaultAPIBase)）",
                    text: $configStore.llmApiBase
                )
                SensitiveTextField(
                    placeholder: selectedLLMProvider.requiresAPIKey
                        ? "LLM API Key（必填）"
                        : "LLM API Key（本地服务一般无需填写）",
                    text: $configStore.llmApiKey
                )
                TextField(
                    selectedLLMProvider == .openai
                        ? "模型名（如 gpt-4o-mini / deepseek-chat）"
                        : "模型名（可留空自动选择）",
                    text: $configStore.llmModel
                )
            }

            TextField("ffmpeg 可执行文件", text: $configStore.ffmpegBin)
            Text("这些配置会保存在本机 `.env` 中。Hugging Face Token 还需要对应账号已接受 pyannote 模型条款。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var storageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("录音缓存和会议纪要默认保存在本机项目目录下。全新安装可直接使用默认位置，也可以在这里先改成你常用的文件夹。后续仍可在设置中调整。")
                .foregroundStyle(.secondary)

            storageField(
                title: "本地录音保存文件夹",
                path: $configStore.recordingsDirectory,
                defaultURL: AppPaths.defaultRecordingsDirectory,
                detail: "默认用于保存本地录音缓存。"
            )

            storageField(
                title: "会议纪要保存文件夹",
                path: $configStore.meetingOutputsDirectory,
                defaultURL: AppPaths.defaultMeetingOutputsDirectory,
                detail: "默认用于保存会议音频副本、转录稿和正式纪要。"
            )

            Text("如果是覆盖升级，已有保存位置会沿用，不会在这里被改回默认值。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var connectivityStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectivityRow(
                title: "飞书",
                status: wizardStore.feishuStatus
            )
            connectivityRow(
                title: "Hugging Face",
                status: wizardStore.huggingFaceStatus
            )
            connectivityRow(
                title: "纪要生成后端（\(selectedLLMProvider.title)）",
                status: wizardStore.llmStatus
            )

            if wizardStore.allPassed {
                Text("配置和连通性均已通过，可以开始使用。")
                    .foregroundStyle(.green)
            } else {
                Text("点击“运行检查”后，会验证飞书凭据、Hugging Face 模型访问和纪要生成后端的可用性。")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func checkList(_ items: [SetupCheckItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.severity.symbolName)
                        .foregroundStyle(item.severity.color)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func connectivityRow(
        title: String,
        status: ConnectivityCheckStatus
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.severity.symbolName)
                .foregroundStyle(status.severity.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func storageField(
        title: String,
        path: Binding<String>,
        defaultURL: URL,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)

            HStack(spacing: 8) {
                TextField(defaultURL.path, text: path)
                Button("选择") {
                    chooseDirectory(for: path)
                }
                Button("默认") {
                    path.wrappedValue = defaultURL.path
                }
            }

            Text("\(detail) 默认：`\(defaultURL.path)`")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func chooseDirectory(for binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: binding.wrappedValue, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }
}
