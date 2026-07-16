import AppKit
import Foundation
import SwiftUI

enum AppAppearance {
    static func resolvedColorScheme(for rawValue: String) -> ColorScheme? {
        switch rawValue {
        case "dark":
            return .dark
        case "light":
            return .light
        default:
            return systemPrefersDark ? .dark : .light
        }
    }

    static func nsAppearance(for rawValue: String) -> NSAppearance? {
        switch rawValue {
        case "dark":
            return NSAppearance(named: .darkAqua)
        case "light":
            return NSAppearance(named: .aqua)
        default:
            return NSAppearance(named: systemPrefersDark ? .darkAqua : .aqua)
        }
    }

    static func synchronizeWindows(for rawValue: String) {
        let appearance = nsAppearance(for: rawValue)
        NSApp.appearance = appearance
        NSApp.windows.forEach { window in
            window.appearance = appearance
            window.contentView?.appearance = appearance
            window.contentView?.needsDisplay = true
        }
    }

    private static var systemPrefersDark: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}

enum AppPreferenceKeys {
    static let appColorTheme = AppColorTheme.storageKey
    static let statusBarIconStyle = "statusBarIconStyle"
    static let statusBarIconColorMode = "statusBarIconColorMode"
}

enum StatusBarIconStyle: String, CaseIterable, Identifiable {
    case waveform
    case pulse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waveform:
            return "声波"
        case .pulse:
            return "脉冲"
        }
    }

    var previewSymbol: String {
        symbol(launchStatus: .running, taskStatus: nil)
    }

    func symbol(launchStatus: LaunchAgentStatus, taskStatus: String?) -> String {
        if launchStatus == .missing || launchStatus == .stopped {
            return alertSymbol
        }

        switch taskStatus {
        case "processing":
            return processingSymbol
        case "done":
            return doneSymbol
        case "error":
            return alertSymbol
        default:
            return idleSymbol
        }
    }

    private var idleSymbol: String {
        switch self {
        case .waveform:
            return "waveform"
        case .pulse:
            return "waveform.path.ecg"
        }
    }

    private var processingSymbol: String {
        idleSymbol
    }

    private var doneSymbol: String {
        switch self {
        case .waveform:
            return "checkmark.circle.fill"
        case .pulse:
            return "checkmark.seal.fill"
        }
    }

    private var alertSymbol: String {
        switch self {
        case .waveform:
            return "exclamationmark.triangle.fill"
        case .pulse:
            return "exclamationmark.octagon.fill"
        }
    }
}

enum StatusBarIconColorMode: String, CaseIterable, Identifiable {
    case white
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white:
            return "白色"
        case .black:
            return "黑色"
        }
    }

    var tintColor: NSColor {
        switch self {
        case .white:
            return NSColor.white.withAlphaComponent(0.92)
        case .black:
            return NSColor.black.withAlphaComponent(0.86)
        }
    }
}

enum MainWindowTabKind: String, CaseIterable, Identifiable {
    case overview
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "概览"
        case .library:
            return "会议库"
        }
    }

    var systemImage: String {
        switch self {
        case .overview:
            return "waveform.path.ecg.rectangle"
        case .library:
            return "books.vertical"
        }
    }

    static func decodeOrder(_ rawValue: String) -> [MainWindowTabKind] {
        var unique: [MainWindowTabKind] = []
        for tab in rawValue
            .split(separator: ",")
            .compactMap({ MainWindowTabKind(rawValue: String($0)) }) where !unique.contains(tab) {
            unique.append(tab)
        }
        let missing = allCases.filter { !unique.contains($0) }
        return unique + missing
    }

    static func encodeOrder(_ order: [MainWindowTabKind]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }
}

enum LLMProviderOption: String, CaseIterable, Identifiable {
    case codex
    case openai
    case anthropic
    case lmStudio = "lm-studio"
    case ollama

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return "Codex CLI"
        case .openai:
            return "OpenAI 兼容 API"
        case .anthropic:
            return "Anthropic API"
        case .lmStudio:
            return "LM Studio（本地）"
        case .ollama:
            return "Ollama（本地）"
        }
    }

    var defaultAPIBase: String {
        switch self {
        case .codex:
            return ""
        case .openai:
            return "https://api.openai.com/v1"
        case .anthropic:
            return "https://api.anthropic.com"
        case .lmStudio:
            return "http://127.0.0.1:1234/v1"
        case .ollama:
            return "http://127.0.0.1:11434/v1"
        }
    }

    var requiresAPIKey: Bool {
        switch self {
        case .openai, .anthropic:
            return true
        case .codex, .lmStudio, .ollama:
            return false
        }
    }

    var usesHTTPAPI: Bool {
        self != .codex
    }

    var configHint: String {
        switch self {
        case .codex:
            return "使用本机 Codex CLI 生成纪要，需要先完成 codex 登录。"
        case .openai:
            return "兼容 OpenAI Chat Completions 协议的服务均可使用（OpenAI、DeepSeek、Kimi、通义千问、智谱等），需填写 API Key 和模型名。"
        case .anthropic:
            return "使用 Anthropic Messages API，需填写 API Key；模型默认 claude-sonnet-4-6。"
        case .lmStudio:
            return "连接本机 LM Studio 服务（默认端口 1234），模型留空时自动使用已加载的模型。"
        case .ollama:
            return "连接本机 Ollama 服务（默认端口 11434），模型留空时自动使用已安装的第一个模型。"
        }
    }
}

final class RuntimeConfigStore: ObservableObject {
    private struct StorageMove {
        let source: URL
        let destination: URL
    }

    @Published var feishuAppID = ""
    @Published var feishuAppSecret = ""
    @Published var hfToken = ""
    @Published var asrEngine = "faster-whisper"
    @Published var asrModel = "small"
    @Published var asrLanguage = "zh"
    @Published var diarizationModel = "pyannote/speaker-diarization-community-1"
    @Published var codexBin = "codex"
    @Published var ffmpegBin = "ffmpeg"
    @Published var llmProvider = LLMProviderOption.codex.rawValue
    @Published var llmApiBase = ""
    @Published var llmApiKey = ""
    @Published var llmModel = ""
    @Published var recordingsDirectory = AppPaths.defaultRecordingsDirectory.path
    @Published var meetingOutputsDirectory = AppPaths.defaultMeetingOutputsDirectory.path
    @Published private(set) var lastSaveMessage: String?

    init() {
        reload()
    }

    var isCoreConfigComplete: Bool {
        !feishuAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !feishuAppSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !feishuAppID.hasPrefix("cli_xxxxxxxxxxxxxxxx")
            && !feishuAppSecret.hasPrefix("replace_with_")
            && !hfToken.hasPrefix("hf_replace_")
    }

    func reload() {
        let values = AppPaths.loadEnvValues()
        feishuAppID = values["FEISHU_APP_ID"] ?? ""
        feishuAppSecret = values["FEISHU_APP_SECRET"] ?? ""
        hfToken = values["HF_TOKEN"] ?? ""
        asrEngine = values["ASR_ENGINE"] ?? "faster-whisper"
        asrModel = values["ASR_MODEL"] ?? "small"
        asrLanguage = values["ASR_LANGUAGE"] ?? "zh"
        diarizationModel = values["DIARIZATION_MODEL"] ?? "pyannote/speaker-diarization-community-1"
        codexBin = values["CODEX_BIN"] ?? "codex"
        ffmpegBin = values["FFMPEG_BIN"] ?? "ffmpeg"
        llmProvider = values["LLM_PROVIDER"] ?? LLMProviderOption.codex.rawValue
        llmApiBase = values["LLM_API_BASE"] ?? ""
        llmApiKey = values["LLM_API_KEY"] ?? ""
        llmModel = values["LLM_MODEL"] ?? ""
        recordingsDirectory = normalizedStoragePath(
            values["RECORDINGS_DIR"],
            defaultURL: AppPaths.defaultRecordingsDirectory
        )
        meetingOutputsDirectory = normalizedStoragePath(
            values["MEETING_OUTPUT_DIR"],
            defaultURL: AppPaths.defaultMeetingOutputsDirectory
        )
    }

    @discardableResult
    func save() -> Bool {
        if let validationError = validateConfiguration() {
            lastSaveMessage = validationError
            return false
        }
        var values = AppPaths.loadEnvValues()
        let currentRecordingsDirectory = AppPaths.resolvedDirectory(
            path: values["RECORDINGS_DIR"],
            defaultURL: AppPaths.defaultRecordingsDirectory
        )
        let currentMeetingOutputsDirectory = AppPaths.resolvedDirectory(
            path: values["MEETING_OUTPUT_DIR"],
            defaultURL: AppPaths.defaultMeetingOutputsDirectory
        )
        let nextRecordingsDirectory = AppPaths.resolvedDirectory(
            path: recordingsDirectory,
            defaultURL: AppPaths.defaultRecordingsDirectory
        )
        let nextMeetingOutputsDirectory = AppPaths.resolvedDirectory(
            path: meetingOutputsDirectory,
            defaultURL: AppPaths.defaultMeetingOutputsDirectory
        )

        let plannedStorageMoves: [StorageMove]
        do {
            plannedStorageMoves = try storageMoves(
                pairs: [
                    (currentRecordingsDirectory, nextRecordingsDirectory),
                    (currentMeetingOutputsDirectory, nextMeetingOutputsDirectory),
                ]
            )
        } catch {
            lastSaveMessage = "保存位置检查失败：\(error.localizedDescription)"
            return false
        }

        let previousSecrets = SecureCredentialStore.values()
        let nextSecrets = [
            "FEISHU_APP_SECRET": feishuAppSecret,
            "HF_TOKEN": hfToken,
            "LLM_API_KEY": llmApiKey,
        ]
        values["FEISHU_APP_ID"] = feishuAppID
        SecureCredentialStore.secretKeys.forEach { values.removeValue(forKey: $0) }
        values["ASR_ENGINE"] = asrEngine
        values["ASR_MODEL"] = asrModel
        values["ASR_LANGUAGE"] = asrLanguage
        values["DIARIZATION_MODEL"] = diarizationModel
        values["CODEX_BIN"] = codexBin
        values["FFMPEG_BIN"] = ffmpegBin
        values["LLM_PROVIDER"] = llmProvider
        values["LLM_API_BASE"] = llmApiBase
        values["LLM_MODEL"] = llmModel
        values["RECORDINGS_DIR"] = nextRecordingsDirectory.path
        values["MEETING_OUTPUT_DIR"] = nextMeetingOutputsDirectory.path

        let preferredOrder = [
            "FEISHU_APP_ID",
            "ASR_ENGINE",
            "ASR_MODEL",
            "ASR_LANGUAGE",
            "DIARIZATION_MODEL",
            "CODEX_BIN",
            "FFMPEG_BIN",
            "LLM_PROVIDER",
            "LLM_API_BASE",
            "LLM_MODEL",
            "RECORDINGS_DIR",
            "MEETING_OUTPUT_DIR",
        ]

        let remainingKeys = values.keys
            .filter { !preferredOrder.contains($0) }
            .sorted()
        let lines = (preferredOrder + remainingKeys)
            .compactMap { key -> String? in
                guard let value = values[key] else {
                    return nil
                }
                return "\(key)=\(value)"
            }
        let previousEnvData = try? Data(contentsOf: AppPaths.envFile)
        do {
            try SecureCredentialStore.replace(with: nextSecrets)
            try lines.joined(separator: "\n")
                .appending("\n")
                .write(to: AppPaths.envFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: AppPaths.envFile.path
            )
            try executeStorageMoves(plannedStorageMoves)
            lastSaveMessage = "配置已保存，敏感凭据已写入系统钥匙串"
            return true
        } catch {
            try? SecureCredentialStore.replace(with: previousSecrets)
            if let previousEnvData {
                try? previousEnvData.write(to: AppPaths.envFile, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: AppPaths.envFile)
            }
            lastSaveMessage = "配置保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func validateConfiguration() -> String? {
        let fields = [
            feishuAppID, feishuAppSecret, hfToken, asrEngine, asrModel,
            asrLanguage, diarizationModel, codexBin, ffmpegBin, llmProvider,
            llmApiBase, llmApiKey, llmModel, recordingsDirectory,
            meetingOutputsDirectory,
        ]
        if fields.contains(where: { $0.contains("\n") || $0.contains("\r") }) {
            return "配置内容不能包含换行符。"
        }

        let provider = LLMProviderOption(rawValue: llmProvider) ?? .codex
        let base = llmApiBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.usesHTTPAPI, !base.isEmpty {
            guard let url = URL(string: base), url.host != nil else {
                return "LLM API 地址无效，请填写完整地址。"
            }
            let host = url.host?.lowercased() ?? ""
            let isLocal = host == "127.0.0.1" || host == "localhost" || host == "::1"
            if url.scheme?.lowercased() != "https" && !isLocal {
                return "远程 LLM API 必须使用 HTTPS；HTTP 仅允许连接本机服务。"
            }
        }
        return nil
    }

    private func normalizedStoragePath(_ rawValue: String?, defaultURL: URL) -> String {
        AppPaths.resolvedDirectory(path: rawValue, defaultURL: defaultURL).path
    }

    private func storageMoves(pairs: [(URL, URL)]) throws -> [StorageMove] {
        let fileManager = FileManager.default
        var moves: [StorageMove] = []
        var destinations = Set<String>()
        for pair in pairs {
            let source = pair.0.standardizedFileURL
            let destination = pair.1.standardizedFileURL
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            guard source != destination, AppPaths.exists(source) else {
                continue
            }
            let items = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for item in items {
                let target = destination.appendingPathComponent(item.lastPathComponent)
                guard !fileManager.fileExists(atPath: target.path),
                      destinations.insert(target.standardizedFileURL.path).inserted else {
                    throw NSError(
                        domain: "MeetingBotStorage",
                        code: 1,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "目标目录已存在同名项目：\(item.lastPathComponent)"
                        ]
                    )
                }
                moves.append(StorageMove(source: item, destination: target))
            }
        }
        return moves
    }

    private func executeStorageMoves(_ moves: [StorageMove]) throws {
        let fileManager = FileManager.default
        var completed: [StorageMove] = []
        do {
            for move in moves {
                try fileManager.moveItem(at: move.source, to: move.destination)
                completed.append(move)
            }
        } catch {
            var rollbackFailures: [String] = []
            for move in completed.reversed() {
                do {
                    try fileManager.moveItem(at: move.destination, to: move.source)
                } catch {
                    rollbackFailures.append(move.destination.lastPathComponent)
                }
            }
            if !rollbackFailures.isEmpty {
                throw NSError(
                    domain: "MeetingBotStorage",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "迁移失败，且以下项目未能自动恢复：\(rollbackFailures.joined(separator: "、"))"
                    ]
                )
            }
            throw error
        }
    }
}

struct RuntimeConfigDraft {
    var feishuAppID = ""
    var feishuAppSecret = ""
    var hfToken = ""
    var asrEngine = "faster-whisper"
    var asrModel = "small"
    var asrLanguage = "zh"
    var diarizationModel = "pyannote/speaker-diarization-community-1"
    var codexBin = "codex"
    var ffmpegBin = "ffmpeg"
    var llmProvider = LLMProviderOption.codex.rawValue
    var llmApiBase = ""
    var llmApiKey = ""
    var llmModel = ""
    var recordingsDirectory = AppPaths.defaultRecordingsDirectory.path
    var meetingOutputsDirectory = AppPaths.defaultMeetingOutputsDirectory.path

    init() {}

    init(store: RuntimeConfigStore) {
        feishuAppID = store.feishuAppID
        feishuAppSecret = store.feishuAppSecret
        hfToken = store.hfToken
        asrEngine = store.asrEngine
        asrModel = store.asrModel
        asrLanguage = store.asrLanguage
        diarizationModel = store.diarizationModel
        codexBin = store.codexBin
        ffmpegBin = store.ffmpegBin
        llmProvider = store.llmProvider
        llmApiBase = store.llmApiBase
        llmApiKey = store.llmApiKey
        llmModel = store.llmModel
        recordingsDirectory = store.recordingsDirectory
        meetingOutputsDirectory = store.meetingOutputsDirectory
    }

    func apply(to store: RuntimeConfigStore) {
        store.feishuAppID = feishuAppID
        store.feishuAppSecret = feishuAppSecret
        store.hfToken = hfToken
        store.asrEngine = asrEngine
        store.asrModel = asrModel
        store.asrLanguage = asrLanguage
        store.diarizationModel = diarizationModel
        store.codexBin = codexBin
        store.ffmpegBin = ffmpegBin
        store.llmProvider = llmProvider
        store.llmApiBase = llmApiBase
        store.llmApiKey = llmApiKey
        store.llmModel = llmModel
        store.recordingsDirectory = recordingsDirectory
        store.meetingOutputsDirectory = meetingOutputsDirectory
    }
}

struct MeetingTemplateDefinition: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var category: String
    var description: String
    var guidance: String
    var isBuiltIn: Bool

    init(
        id: String,
        name: String,
        category: String = "通用",
        description: String,
        guidance: String,
        isBuiltIn: Bool
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.description = description
        self.guidance = guidance
        self.isBuiltIn = isBuiltIn
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case description
        case guidance
        case isBuiltIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "通用"
        description = try container.decode(String.self, forKey: .description)
        guidance = try container.decode(String.self, forKey: .guidance)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
    }
}

struct MeetingTemplateCatalogDocument: Codable {
    var templates: [MeetingTemplateDefinition]
}

final class MeetingTemplateCatalogStore: ObservableObject {
    @Published var templates: [MeetingTemplateDefinition] = []
    @Published var selectedTemplateID: String?
    @Published private(set) var lastErrorMessage: String?

    init() {
        reload()
    }

    var selectedTemplate: Binding<MeetingTemplateDefinition>? {
        guard let selectedTemplateID,
              let index = templates.firstIndex(where: { $0.id == selectedTemplateID }) else {
            return nil
        }

        return Binding(
            get: { self.templates[index] },
            set: { self.templates[index] = $0 }
        )
    }

    func reload() {
        guard AppPaths.exists(AppPaths.templateCatalogFile),
              let data = try? Data(contentsOf: AppPaths.templateCatalogFile),
              let document = try? JSONDecoder().decode(MeetingTemplateCatalogDocument.self, from: data) else {
            templates = Self.defaultTemplates
            selectedTemplateID = templates.first?.id
            save()
            return
        }

        templates = reconciledTemplates(from: document.templates)
        if templates.isEmpty {
            templates = Self.defaultTemplates
        }
        if selectedTemplateID == nil || !templates.contains(where: { $0.id == selectedTemplateID }) {
            selectedTemplateID = templates.first?.id
        }
    }

    func addTemplate(category rawCategory: String? = nil) {
        let baseID = "custom_template"
        var suffix = 1
        var nextID = "\(baseID)_\(suffix)"
        while templates.contains(where: { $0.id == nextID }) {
            suffix += 1
            nextID = "\(baseID)_\(suffix)"
        }

        let category = rawCategory?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCategory = (category?.isEmpty == false) ? category! : "自定义"
        let template = MeetingTemplateDefinition(
            id: nextID,
            name: "自定义会议类型",
            category: normalizedCategory,
            description: "用于自定义会议分类。",
            guidance: "请根据该会议类型整理会议重点、结论和后续安排。",
            isBuiltIn: false
        )
        templates.append(template)
        selectedTemplateID = template.id
        save()
    }

    func deleteSelectedTemplate() {
        guard let selectedTemplateID,
              let selected = templates.first(where: { $0.id == selectedTemplateID }),
              !selected.isBuiltIn else {
            return
        }

        templates.removeAll { $0.id == selectedTemplateID }
        self.selectedTemplateID = templates.first?.id
        save()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.libraryDirectory,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(MeetingTemplateCatalogDocument(templates: templates))
            try data.write(to: AppPaths.templateCatalogFile, options: .atomic)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "模板保存失败：\(error.localizedDescription)"
        }
    }

    static let defaultTemplates: [MeetingTemplateDefinition] = [
        MeetingTemplateDefinition(
            id: "general_meeting",
            name: "通用会议纪要",
            category: "通用",
            description: "适合难以进一步归类的常规会议。",
            guidance: "以结论、行动项、讨论主题为主线整理会议内容。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "research_discussion",
            name: "科研讨论会",
            category: "科研与专业",
            description: "适合学术讨论、研究进展和方案评议。",
            guidance: "突出研究问题、方法、证据、争议点和下一步实验。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "project_progress",
            name: "项目推进会",
            category: "项目与管理",
            description: "适合项目进度、任务协调和风险跟踪。",
            guidance: "突出里程碑、当前进展、阻塞项、责任人和下一步动作。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "expert_consultation",
            name: "专家咨询 / 评审意见整理",
            category: "科研与专业",
            description: "适合专家咨询、评审会和外部意见收集。",
            guidance: "突出专家观点、共识、分歧、建议和需要吸收的修改。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "management_meeting",
            name: "管理工作会",
            category: "项目与管理",
            description: "适合部门协调、经营管理和组织议题。",
            guidance: "突出决策、分工、时间节点、风险和跨部门协同。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "interview_summary",
            name: "访谈 / 座谈整理",
            category: "调研与访谈",
            description: "适合访谈、座谈和深度交流。",
            guidance: "突出受访者观点、代表性表述、主题归纳和待验证问题。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "parent_teacher_meeting",
            name: "家长会 / 家校沟通",
            category: "教育与培训",
            description: "适合家长会、家校沟通和学生成长反馈。",
            guidance: "突出学生表现、家校共识、待跟进问题和后续协同安排。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "legal_communication",
            name: "法律沟通 / 合规讨论",
            category: "法务与合规",
            description: "适合法律咨询、合同讨论、合规风险沟通。",
            guidance: "突出事实背景、法律问题、风险判断、待确认材料和后续动作。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "sales_conversion",
            name: "销售转化 / 商机推进",
            category: "销售与客户",
            description: "适合客户需求沟通、销售跟进和转化推进。",
            guidance: "突出客户诉求、购买信号、异议、决策链、下一步转化动作。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "customer_success",
            name: "客户成功 / 服务复盘",
            category: "销售与客户",
            description: "适合客户回访、交付复盘和续约沟通。",
            guidance: "突出使用现状、满意度、问题闭环、价值验证和续约风险。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "product_development",
            name: "产品研发会",
            category: "产品与研发",
            description: "适合需求评审、方案讨论、版本计划和研发协同。",
            guidance: "突出用户问题、需求范围、技术方案、取舍、排期和责任人。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "product_review",
            name: "产品评审 / 设计评审",
            category: "产品与研发",
            description: "适合 PRD、交互、设计或上线前评审。",
            guidance: "突出评审对象、通过项、待修改项、风险和验收标准。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "recruitment_interview",
            name: "招聘面试 / 候选人评估",
            category: "人力与组织",
            description: "适合招聘面试、复试和候选人校准。",
            guidance: "突出候选人背景、关键证据、优势、疑虑和录用建议。",
            isBuiltIn: true
        ),
        MeetingTemplateDefinition(
            id: "training_workshop",
            name: "培训 / 工作坊",
            category: "教育与培训",
            description: "适合培训授课、共创工作坊和学习复盘。",
            guidance: "突出目标、核心内容、参与反馈、练习结果和后续任务。",
            isBuiltIn: true
        ),
    ]

    private func reconciledTemplates(from loadedTemplates: [MeetingTemplateDefinition]) -> [MeetingTemplateDefinition] {
        var templatesByID = Dictionary(uniqueKeysWithValues: loadedTemplates.map { ($0.id, $0) })

        for builtIn in Self.defaultTemplates {
            if var existing = templatesByID[builtIn.id] {
                if existing.isBuiltIn, existing.category == "通用", builtIn.category != "通用" {
                    existing.category = builtIn.category
                    templatesByID[builtIn.id] = existing
                }
            } else {
                templatesByID[builtIn.id] = builtIn
            }
        }

        return loadedTemplates
            .compactMap { templatesByID.removeValue(forKey: $0.id) }
            + Self.defaultTemplates.compactMap { templatesByID.removeValue(forKey: $0.id) }
            + templatesByID.values.sorted { $0.name < $1.name }
    }
}

struct SensitiveTextField: View {
    let placeholder: String
    @Binding var text: String
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "隐藏内容" : "显示内容")
        }
    }
}

struct SettingsWindowView: View {
    @ObservedObject var runtimeStore: BotRuntimeStore
    @ObservedObject var libraryStore: MeetingLibraryStore
    @ObservedObject var configStore: RuntimeConfigStore
    @ObservedObject var templateStore: MeetingTemplateCatalogStore
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("preferredMainColorScheme") private var preferredMainColorScheme = "system"
    @AppStorage(AppPreferenceKeys.appColorTheme) private var appColorTheme = AppColorTheme.green.rawValue
    @AppStorage(AppPreferenceKeys.statusBarIconStyle) private var statusBarIconStyle = StatusBarIconStyle.waveform.rawValue
    @AppStorage(AppPreferenceKeys.statusBarIconColorMode) private var statusBarIconColorMode = StatusBarIconColorMode.white.rawValue
    @AppStorage("showOverviewTab") private var showOverviewTab = false
    @AppStorage("mainTabOrder") private var mainTabOrderRaw = "library,overview"
    @State private var advancedSettingsTab: AdvancedSettingsTab = .storageLocations
    @State private var minutesSettingsTab: MinutesSettingsTab = .meetingTypes
    @State private var configDraft = RuntimeConfigDraft()
    @State private var storageMigrationNotice: String?
    @State private var isCreatingTemplateCategory = false
    @State private var pendingTemplateCategoryName = ""

    private var tabOrder: [MainWindowTabKind] {
        MainWindowTabKind.decodeOrder(mainTabOrderRaw)
    }

    var body: some View {
        TabView {
            statusAndServiceTab
                .tabItem {
                    Label("状态与服务", systemImage: "waveform.path.ecg")
                }

            appearanceTab
                .tabItem {
                    Label("外观", systemImage: "paintpalette")
                }

            minutesSettingsTabView
                .tabItem {
                    Label("纪要设置", systemImage: "text.badge.plus")
                }

            advancedTab
                .tabItem {
                    Label("高级设置", systemImage: "gearshape.2")
                }
        }
        .frame(minWidth: 760, minHeight: 500)
        .padding(18)
        .tint(.brandAccent)
        .preferredColorScheme(AppAppearance.resolvedColorScheme(for: preferredMainColorScheme))
        .onAppear {
            configDraft = RuntimeConfigDraft(store: configStore)
            AppAppearance.synchronizeWindows(for: preferredMainColorScheme)
        }
        .onChange(of: preferredMainColorScheme) { _, newValue in
            AppAppearance.synchronizeWindows(for: newValue)
        }
        .animation(.easeInOut(duration: 0.15), value: appColorTheme)
    }

    private var statusAndServiceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) {
                        versionSettingsCard
                        serviceSettingsCard
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    environmentSettingsCard
                        .frame(maxWidth: .infinity, minHeight: 190, alignment: .top)
                }

                runtimeStatusSettingsCard
            }
            .frame(maxWidth: 740)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var appearanceTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsCard("标签页顺序") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(tabOrder.enumerated()), id: \.element) { index, tab in
                            HStack {
                                Label(tab.title, systemImage: tab.systemImage)
                                Spacer()
                                Button {
                                    moveTab(at: index, offset: -1)
                                } label: {
                                    Image(systemName: "arrow.up")
                                }
                                .disabled(index == 0)

                                Button {
                                    moveTab(at: index, offset: 1)
                                } label: {
                                    Image(systemName: "arrow.down")
                                }
                                .disabled(index == tabOrder.count - 1)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                settingsCard("显示模式") {
                    Picker("显示模式", selection: $preferredMainColorScheme) {
                        Text("跟随系统外观").tag("system")
                        Text("白天").tag("light")
                        Text("夜览").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }

                settingsCard("配色方案") {
                    colorThemePicker

                    Text("影响主界面强调色、卡片顶栏、按钮选中态和设置页高亮。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingsCard("状态栏图标") {
                    VStack(alignment: .leading, spacing: 12) {
                        settingsField("图标方案") {
                            statusBarIconStylePicker
                        } hint: {
                            Text("只影响菜单栏中的小图标，不改变 App 图标。")
                        }

                        settingsField("图标颜色") {
                            Picker("图标颜色", selection: $statusBarIconColorMode) {
                                ForEach(StatusBarIconColorMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 240, alignment: .leading)
                        } hint: {
                            Text("白色适合深色菜单栏或深色壁纸；黑色适合浅色菜单栏。")
                        }
                    }
                }
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var advancedTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("高级设置", selection: $advancedSettingsTab) {
                    ForEach(AdvancedSettingsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, alignment: .center)

                switch advancedSettingsTab {
                case .storageLocations:
                    settingsCard("保存位置") {
                        VStack(alignment: .leading, spacing: 12) {
                            settingsField("本地录音保存文件夹") {
                                storagePathField(
                                    path: $configDraft.recordingsDirectory,
                                    defaultURL: AppPaths.defaultRecordingsDirectory,
                                    title: "本地录音"
                                )
                            } hint: {
                                Text("默认：`\(AppPaths.defaultRecordingsDirectory.path)`。保存后会把现有录音缓存迁移到新目录。")
                            }

                            settingsField("会议纪要保存文件夹") {
                                storagePathField(
                                    path: $configDraft.meetingOutputsDirectory,
                                    defaultURL: AppPaths.defaultMeetingOutputsDirectory,
                                    title: "会议纪要"
                                )
                            } hint: {
                                Text("默认：`\(AppPaths.defaultMeetingOutputsDirectory.path)`。该目录保存会议音频副本、转录稿和正式纪要。")
                            }

                            Text("更改保存位置后，保存并重启服务即可让后台开始使用新目录。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                case .botConfiguration:
                    settingsCard("机器人配置") {
                        VStack(alignment: .leading, spacing: 12) {
                            settingsField("飞书 App ID") {
                                TextField("例如：cli_xxxxxxxxxxxxxxxx", text: $configDraft.feishuAppID)
                            } hint: {
                                Text("来自飞书开放平台自建应用，用于让机器人接收和回复消息。")
                            }

                            settingsField("飞书 App Secret") {
                                SensitiveTextField(placeholder: "输入 App Secret", text: $configDraft.feishuAppSecret)
                            } hint: {
                                Text("与 App ID 配套使用。保存后仅写入本机 `.env`。")
                            }

                            settingsField("Hugging Face Token") {
                                SensitiveTextField(placeholder: "输入 Hugging Face Token", text: $configDraft.hfToken)
                            } hint: {
                                Text("用于说话人分离模型访问；账号仍需先接受 pyannote 模型条款。")
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                case .speechEngine:
                    settingsCard("语音转写引擎") {
                        VStack(alignment: .leading, spacing: 12) {
                            settingsField("语音转写引擎") {
                                Picker("语音转写引擎", selection: $configDraft.asrEngine) {
                                    Text("faster-whisper").tag("faster-whisper")
                                }
                            } hint: {
                                Text("当前版本内置并验证的是 faster-whisper。")
                            }

                            settingsField("语音转写模型") {
                                Picker("语音转写模型", selection: $configDraft.asrModel) {
                                    ForEach(asrModelOptions, id: \.self) { option in
                                        Text(option).tag(option)
                                    }
                                }
                            } hint: {
                                Text("常用值：tiny、base、small、medium、large-v3；模型越大通常越准，也越慢。")
                            }

                            settingsField("语音识别语言") {
                                Picker("语音识别语言", selection: $configDraft.asrLanguage) {
                                    ForEach(asrLanguageOptions, id: \.value) { option in
                                        Text(option.label).tag(option.value)
                                    }
                                }
                            } hint: {
                                Text("默认使用中文 zh；如果音频语言不固定，可选“自动检测”。")
                            }

                            settingsField("说话人分离模型") {
                                TextField("模型名称", text: $configDraft.diarizationModel)
                            } hint: {
                                Text("默认值为 pyannote/speaker-diarization-community-1，通常无需修改。")
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                case .toolPaths:
                    settingsCard("纪要生成（LLM 后端）") {
                        VStack(alignment: .leading, spacing: 12) {
                            settingsField("生成后端") {
                                Picker("", selection: $configDraft.llmProvider) {
                                    ForEach(LLMProviderOption.allCases) { option in
                                        Text(option.title).tag(option.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            } hint: {
                                Text(selectedLLMProvider.configHint)
                            }

                            if selectedLLMProvider.usesHTTPAPI {
                                settingsField("API 地址") {
                                    TextField(
                                        selectedLLMProvider.defaultAPIBase.isEmpty
                                            ? "https://…"
                                            : "留空使用 \(selectedLLMProvider.defaultAPIBase)",
                                        text: $configDraft.llmApiBase
                                    )
                                } hint: {
                                    Text("留空时使用所选后端的默认地址。")
                                }

                                settingsField("API Key") {
                                    SensitiveTextField(
                                        placeholder: selectedLLMProvider.requiresAPIKey
                                            ? "必填"
                                            : "本地服务一般无需填写",
                                        text: $configDraft.llmApiKey
                                    )
                                } hint: {
                                    Text("仅保存在本机 `.env` 中。")
                                }

                                settingsField("模型") {
                                    TextField(
                                        selectedLLMProvider == .anthropic
                                            ? "留空使用 claude-sonnet-4-6"
                                            : (selectedLLMProvider == .openai
                                                ? "如 gpt-4o-mini / deepseek-chat"
                                                : "留空自动使用已加载模型"),
                                        text: $configDraft.llmModel
                                    )
                                } hint: {
                                    Text("OpenAI 兼容服务必须填写模型名；本地服务可留空自动选择。")
                                }
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    }

                    settingsCard("工具路径") {
                        VStack(alignment: .leading, spacing: 12) {
                            settingsField("Codex CLI") {
                                TextField("命令名或绝对路径", text: $configDraft.codexBin)
                            } hint: {
                                Text(toolPathHint(for: "codex", fallback: "可填写 `codex`，或填写类似 `/opt/homebrew/bin/codex` 的绝对路径。"))
                            }

                            settingsField("ffmpeg") {
                                TextField("命令名或绝对路径", text: $configDraft.ffmpegBin)
                            } hint: {
                                Text(toolPathHint(for: "ffmpeg", fallback: "可填写 `ffmpeg`，或填写类似 `/opt/homebrew/bin/ffmpeg` 的绝对路径。"))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }

                HStack {
                    Button("保存配置") {
                        configDraft.apply(to: configStore)
                        configStore.save()
                        runtimeStore.refresh()
                        libraryStore.reload(forceScan: true)
                    }
                    Button("保存并重启服务") {
                        configDraft.apply(to: configStore)
                        configStore.save()
                        runtimeStore.restartService()
                        libraryStore.reload(forceScan: true)
                    }
                    Spacer()
                    if let message = configStore.lastSaveMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .alert("将迁移原有数据", isPresented: Binding(
            get: { storageMigrationNotice != nil },
            set: { isPresented in
                if !isPresented {
                    storageMigrationNotice = nil
                }
            }
        )) {
            Button("知道了") {
                storageMigrationNotice = nil
            }
        } message: {
            Text(storageMigrationNotice ?? "")
        }
    }

    private var selectedLLMProvider: LLMProviderOption {
        LLMProviderOption(rawValue: configDraft.llmProvider) ?? .codex
    }

    private var asrModelOptions: [String] {
        let known = ["tiny", "base", "small", "medium", "large-v3"]
        return known.contains(configDraft.asrModel) ? known : [configDraft.asrModel] + known
    }

    private var asrLanguageOptions: [(label: String, value: String)] {
        var known: [(label: String, value: String)] = [
            ("自动检测", ""),
            ("中文 zh", "zh"),
            ("英语 en", "en"),
            ("日语 ja", "ja"),
        ]
        if !known.contains(where: { $0.value == configDraft.asrLanguage }) {
            known.insert(("自定义 \(configDraft.asrLanguage)", configDraft.asrLanguage), at: 0)
        }
        return known
    }

    private var statusBarIconStylePicker: some View {
        HStack(spacing: 10) {
            ForEach(StatusBarIconStyle.allCases) { style in
                let isSelected = statusBarIconStyle == style.rawValue
                Button {
                    statusBarIconStyle = style.rawValue
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: style.previewSymbol)
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: 34, height: 28)
                        Text(style.title)
                            .font(.caption)
                    }
                    .foregroundStyle(isSelected ? Color.brandAccent : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .frame(width: 112)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.brandAccentSoft : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.brandAccent.opacity(0.65) : Color(nsColor: .separatorColor))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            if AppColorTheme(rawValue: appColorTheme) == nil {
                appColorTheme = AppColorTheme.green.rawValue
            }
            if StatusBarIconStyle(rawValue: statusBarIconStyle) == nil {
                statusBarIconStyle = StatusBarIconStyle.waveform.rawValue
            }
            if StatusBarIconColorMode(rawValue: statusBarIconColorMode) == nil {
                statusBarIconColorMode = StatusBarIconColorMode.white.rawValue
            }
        }
    }

    private var colorThemePicker: some View {
        HStack(spacing: 10) {
            ForEach(AppColorTheme.allCases) { theme in
                let isSelected = appColorTheme == theme.rawValue
                Button {
                    appColorTheme = theme.rawValue
                } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.accentColor)
                            .frame(width: 18, height: 18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.55))
                            )

                        Text(theme.title)
                            .font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(isSelected ? Color.brandAccent : Color.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(width: 86)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? theme.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? theme.accentColor.opacity(0.65) : Color(nsColor: .separatorColor))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            if AppColorTheme(rawValue: appColorTheme) == nil {
                appColorTheme = AppColorTheme.green.rawValue
            }
        }
    }

    private func toolPathHint(for checkID: String, fallback: String) -> String {
        guard let check = runtimeStore.environmentChecks.first(where: { $0.id == checkID }),
              check.isHealthy else {
            return fallback
        }

        return "当前已解析为 `\(check.detail)`。\(fallback)"
    }

    private func storagePathField(
        path: Binding<String>,
        defaultURL: URL,
        title: String
    ) -> some View {
        HStack(spacing: 8) {
            TextField(defaultURL.path, text: path)
            Button("选择") {
                chooseDirectory(for: path, title: title)
            }
            Button {
                openStorageDirectory(path.wrappedValue)
            } label: {
                Image(systemName: "folder")
            }
            .help("打开当前文件夹")
            Button("默认") {
                path.wrappedValue = defaultURL.path
            }
        }
    }

    private func chooseDirectory(for binding: Binding<String>, title: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: binding.wrappedValue, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            let previousPath = binding.wrappedValue
            binding.wrappedValue = url.path
            if previousPath != url.path {
                storageMigrationNotice =
                    "选择新的\(title)文件夹后，保存配置时会自动把原有数据迁移到新位置。"
            }
        }
    }

    private func openStorageDirectory(_ rawPath: String) {
        let url = URL(fileURLWithPath: rawPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        FileOpener.open(url)
    }

    @ViewBuilder
    private func settingsField<Content: View, Hint: View>(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder hint: () -> Hint
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
            hint()
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var minutesSettingsTabView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("纪要设置", selection: $minutesSettingsTab) {
                    ForEach(MinutesSettingsTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity, alignment: .center)

                switch minutesSettingsTab {
                case .meetingTypes:
                    settingsCard("会议类型") {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 8) {
                                List(selection: $templateStore.selectedTemplateID) {
                                    ForEach(templateCategorySections, id: \.category) { section in
                                        Section(section.category) {
                                            ForEach(section.templates) { template in
                                                Text(template.name)
                                                    .tag(template.id)
                                            }
                                        }
                                    }
                                }
                                .frame(width: 220, height: 320)

                                HStack {
                                    Button {
                                        pendingTemplateCategoryName = ""
                                        isCreatingTemplateCategory = true
                                    } label: {
                                        Label("类别", systemImage: "folder.badge.plus")
                                    }
                                    Spacer()
                                    Button {
                                        templateStore.addTemplate()
                                    } label: {
                                        Label("类型", systemImage: "plus.square")
                                    }
                                    Spacer()
                                    Button {
                                        templateStore.deleteSelectedTemplate()
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                    .disabled(templateStore.selectedTemplate?.wrappedValue.isBuiltIn ?? true)
                                }
                                .frame(width: 220)
                            }

                            if let template = templateStore.selectedTemplate {
                                VStack(alignment: .leading, spacing: 10) {
                                    settingsField("类别") {
                                        TextField("例如：项目与管理", text: template.category)
                                    } hint: {
                                        EmptyView()
                                    }
                                    settingsField("类型名称") {
                                        TextField("例如：项目推进会", text: template.name)
                                    } hint: {
                                        EmptyView()
                                    }
                                    settingsField("说明") {
                                        TextField("一句话说明该类型适用场景", text: template.description)
                                    } hint: {
                                        EmptyView()
                                    }
                                    settingsField("生成指引") {
                                        TextEditor(text: template.guidance)
                                            .font(.body)
                                            .frame(minHeight: 120)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color(nsColor: .separatorColor))
                                            )
                                    } hint: {
                                        EmptyView()
                                    }
                                    HStack {
                                        Spacer()
                                        Button("保存模板") {
                                            templateStore.save()
                                        }
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                case .labels:
                    settingsCard("标签") {
                        QuickLabelManager(store: libraryStore)
                    }
                }
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .alert("新增类别", isPresented: $isCreatingTemplateCategory) {
            TextField("类别名称", text: $pendingTemplateCategoryName)
            Button("取消", role: .cancel) {
                pendingTemplateCategoryName = ""
            }
            Button("创建") {
                templateStore.addTemplate(category: pendingTemplateCategoryName)
                pendingTemplateCategoryName = ""
            }
        } message: {
            Text("会在新类别下创建一个可编辑的会议类型。")
        }
    }

    private var versionSettingsCard: some View {
        settingsCard("版本") {
            Text(AppVersion.current)
                .font(.title3.weight(.semibold))
        }
    }

    private var serviceSettingsCard: some View {
        settingsCard("服务") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button("启动", systemImage: "play.fill") {
                        runtimeStore.startService()
                    }
                    Button("停止", systemImage: "stop.fill") {
                        runtimeStore.stopService()
                    }
                    Button("重启", systemImage: "arrow.clockwise") {
                        runtimeStore.restartService()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(runtimeStore.launchStatus == .missing || runtimeStore.isServiceActionRunning)

                Toggle(
                    isOn: Binding(
                        get: { runtimeStore.launchAtLoginEnabled },
                        set: { runtimeStore.setLaunchAtLoginEnabled($0) }
                    )
                ) {
                    Label("开机启动", systemImage: "power")
                }
                .toggleStyle(.checkbox)

                Toggle(isOn: $notificationsEnabled) {
                    Label("纪要完成后发送系统通知", systemImage: "bell")
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private var environmentSettingsCard: some View {
        settingsCard("环境检查") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(runtimeStore.environmentChecks) { check in
                    HStack(spacing: 10) {
                        Image(systemName: check.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(check.isHealthy ? .green : .orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var runtimeStatusSettingsCard: some View {
        settingsCard("运行状态") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    settingsMetric(
                        title: "服务",
                        value: runtimeStore.launchStatus.displayName,
                        systemImage: runtimeStore.launchStatus.symbolName,
                        color: runtimeStore.launchStatus.tintColor
                    )
                    settingsMetric(
                        title: "任务",
                        value: runtimeStore.runtimeStatus?.taskDisplayName ?? "未读取",
                        systemImage: runtimeStore.runtimeStatus?.taskSymbolName ?? "circle.dashed",
                        color: runtimeStore.runtimeStatus?.taskTintColor ?? .secondary
                    )
                    settingsMetric(
                        title: "阶段",
                        value: runtimeStore.runtimeStatus?.stageDisplayName ?? "未知",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        color: .blue
                    )
                }

                Divider()

                HStack(spacing: 10) {
                    Label("最近更新", systemImage: "clock")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(runtimeStore.runtimeStatus?.updatedAtDisplay ?? "未知")
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.callout)
            }
        }
    }

    private func settingsMetric(
        title: String,
        value: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func settingsCard<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: NSFont.systemFontSize + 2, weight: .semibold))
            GroupBox {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func moveTab(at index: Int, offset: Int) {
        var order = tabOrder
        let targetIndex = index + offset
        guard order.indices.contains(index), order.indices.contains(targetIndex) else {
            return
        }
        order.swapAt(index, targetIndex)
        mainTabOrderRaw = MainWindowTabKind.encodeOrder(order)
    }

    private var templateCategorySections: [(category: String, templates: [MeetingTemplateDefinition])] {
        let grouped = Dictionary(grouping: templateStore.templates, by: \.category)
        return grouped
            .map { category, templates in
                (category, templates.sorted { $0.name < $1.name })
            }
            .sorted { lhs, rhs in
                if lhs.category == "通用" {
                    return true
                }
                if rhs.category == "通用" {
                    return false
                }
                if lhs.category == "自定义" {
                    return false
                }
                if rhs.category == "自定义" {
                    return true
                }
                return lhs.category < rhs.category
            }
    }
}

private enum AdvancedSettingsTab: String, CaseIterable, Identifiable {
    case storageLocations
    case botConfiguration
    case speechEngine
    case toolPaths

    var id: String { rawValue }

    var title: String {
        switch self {
        case .storageLocations:
            return "保存位置"
        case .botConfiguration:
            return "机器人配置"
        case .speechEngine:
            return "语音转写引擎"
        case .toolPaths:
            return "工具路径"
        }
    }
}

private enum MinutesSettingsTab: String, CaseIterable, Identifiable {
    case meetingTypes
    case labels

    var id: String { rawValue }

    var title: String {
        switch self {
        case .labels:
            return "标签"
        case .meetingTypes:
            return "会议类型"
        }
    }
}

struct QuickLabelManager: View {
    @ObservedObject var store: MeetingLibraryStore
    @State private var newLabel = ""
    @State private var editingLabel: String?
    @State private var editingValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("新增标签，可用逗号分隔多个", text: $newLabel)
                Button("添加") {
                    store.addGlobalLabels(newLabel)
                    newLabel = ""
                }
                .disabled(newLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .textFieldStyle(.roundedBorder)

            FlexibleChipRow(
                items: store.globalLabels,
                minimumWidth: 88,
                maximumWidth: 150,
                expandsItems: false,
                columnSpacing: 4,
                rowSpacing: 4
            ) { label in
                HStack(spacing: 6) {
                    Text(label)
                    Button {
                        store.removeGlobalLabel(label)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .contextMenu {
                    Button("重命名") {
                        editingLabel = label
                        editingValue = label
                    }
                    Button("删除", role: .destructive) {
                        store.removeGlobalLabel(label)
                    }
                }
            }
        }
        .alert("重命名标签", isPresented: Binding(
            get: { editingLabel != nil },
            set: { isPresented in
                if !isPresented {
                    editingLabel = nil
                    editingValue = ""
                }
            }
        )) {
            TextField("标签名称", text: $editingValue)
            Button("取消", role: .cancel) {
                editingLabel = nil
                editingValue = ""
            }
            Button("保存") {
                if let editingLabel {
                    store.renameGlobalLabel(editingLabel, to: editingValue)
                }
                editingLabel = nil
                editingValue = ""
            }
        }
    }
}
