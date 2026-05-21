import Foundation

enum LaunchAgentStatus: Equatable {
    case running
    case stopped
    case unknown
    case missing

    var displayName: String {
        switch self {
        case .running:
            return "运行中"
        case .stopped:
            return "已停止"
        case .unknown:
            return "状态未知"
        case .missing:
            return "未找到配置"
        }
    }

    var symbolName: String {
        switch self {
        case .running:
            return "checkmark.circle.fill"
        case .stopped:
            return "pause.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        case .missing:
            return "exclamationmark.triangle.fill"
        }
    }
}

struct RuntimeStatus: Decodable, Equatable {
    let serviceStatus: String
    let taskStatus: String
    let stage: String
    let message: String
    let sessionID: String
    let sessionDirectory: String
    let latestPDF: String
    let latestDOCX: String
    let latestHTML: String
    let latestMD: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case serviceStatus = "service_status"
        case taskStatus = "task_status"
        case stage
        case message
        case sessionID = "session_id"
        case sessionDirectory = "session_dir"
        case latestPDF = "latest_pdf"
        case latestDOCX = "latest_docx"
        case latestHTML = "latest_html"
        case latestMD = "latest_md"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serviceStatus = try container.decodeIfPresent(String.self, forKey: .serviceStatus) ?? "unknown"
        taskStatus = try container.decodeIfPresent(String.self, forKey: .taskStatus) ?? "idle"
        stage = try container.decodeIfPresent(String.self, forKey: .stage) ?? "idle"
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        sessionDirectory = try container.decodeIfPresent(String.self, forKey: .sessionDirectory) ?? ""
        latestPDF = try container.decodeIfPresent(String.self, forKey: .latestPDF) ?? ""
        latestDOCX = try container.decodeIfPresent(String.self, forKey: .latestDOCX) ?? ""
        latestHTML = try container.decodeIfPresent(String.self, forKey: .latestHTML) ?? ""
        latestMD = try container.decodeIfPresent(String.self, forKey: .latestMD) ?? ""
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    var taskDisplayName: String {
        switch taskStatus {
        case "idle":
            return "空闲"
        case "processing":
            return "处理中"
        case "done":
            return "已完成"
        case "error":
            return "失败"
        default:
            return taskStatus.isEmpty ? "状态未知" : taskStatus
        }
    }

    var stageDisplayName: String {
        StageDisplay.name(for: stage)
    }

    var updatedAtDisplay: String {
        DateDisplay.displayString(fromISO8601: updatedAt)
    }

    var latestPDFURL: URL? {
        AppPaths.existingURL(path: latestPDF)
    }

    var latestDOCXURL: URL? {
        AppPaths.existingURL(path: latestDOCX)
    }

    var latestHTMLURL: URL? {
        AppPaths.existingURL(path: latestHTML)
    }

    var latestMDURL: URL? {
        AppPaths.existingURL(path: latestMD)
    }

    var sessionURL: URL? {
        AppPaths.existingURL(path: sessionDirectory)
    }
}

struct MeetingDoneEvent: Decodable, Equatable, Identifiable {
    var eventFileName: String = ""
    let event: String
    let sessionID: String
    let sessionDirectory: String
    let version: String
    let reportTitle: String
    let summaryDOCX: String
    let summaryPDF: String
    let summaryHTML: String
    let summaryMD: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case event
        case sessionID = "session_id"
        case sessionDirectory = "session_dir"
        case version
        case reportTitle = "report_title"
        case summaryDOCX = "summary_docx"
        case summaryPDF = "summary_pdf"
        case summaryHTML = "summary_html"
        case summaryMD = "summary_md"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decodeIfPresent(String.self, forKey: .event) ?? ""
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID) ?? ""
        sessionDirectory = try container.decodeIfPresent(String.self, forKey: .sessionDirectory) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "anonymous"
        reportTitle = try container.decodeIfPresent(String.self, forKey: .reportTitle) ?? "智能会议纪要"
        summaryDOCX = try container.decodeIfPresent(String.self, forKey: .summaryDOCX) ?? ""
        summaryPDF = try container.decodeIfPresent(String.self, forKey: .summaryPDF) ?? ""
        summaryHTML = try container.decodeIfPresent(String.self, forKey: .summaryHTML) ?? ""
        summaryMD = try container.decodeIfPresent(String.self, forKey: .summaryMD) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

    var id: String {
        eventFileName.isEmpty ? "\(sessionID)-\(version)-\(createdAt)" : eventFileName
    }

    var versionDisplayName: String {
        version == "named" ? "实名版" : "匿名版"
    }

    var titleDisplayName: String {
        reportTitle.isEmpty ? sessionID : reportTitle
    }

    var createdDate: Date? {
        DateDisplay.date(fromISO8601: createdAt)
    }

    var createdAtDisplay: String {
        DateDisplay.displayString(fromISO8601: createdAt)
    }

    var pdfURL: URL? {
        AppPaths.existingURL(path: summaryPDF)
    }

    var docxURL: URL? {
        AppPaths.existingURL(path: summaryDOCX)
    }

    var htmlURL: URL? {
        AppPaths.existingURL(path: summaryHTML)
    }

    var mdURL: URL? {
        AppPaths.existingURL(path: summaryMD)
    }

    var sessionURL: URL? {
        AppPaths.existingURL(path: sessionDirectory)
    }
}

enum StageDisplay {
    static func name(for stage: String) -> String {
        switch stage {
        case "idle":
            return "空闲"
        case "received_audio":
            return "已收到录音"
        case "downloading_audio":
            return "正在下载录音"
        case "converting_audio":
            return "正在转换音频"
        case "diarization":
            return "正在进行说话人分离"
        case "transcribing":
            return "正在语音转写"
        case "aligning_speakers":
            return "正在对齐说话人"
        case "reusing_transcript":
            return "正在复用已有转录"
        case "classifying_meeting":
            return "正在识别会议类型"
        case "generating_report":
            return "正在生成会议纪要"
        case "generating_docx":
            return "正在生成 DOCX"
        case "generating_report_exports":
            return "正在生成 HTML"
        case "generating_pdf":
            return "正在生成 PDF"
        case "uploading_to_feishu":
            return "正在回传飞书"
        case "done":
            return "已完成"
        case "error":
            return "处理失败"
        default:
            return stage.isEmpty ? "状态未知" : stage
        }
    }
}

enum DateDisplay {
    static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterWithoutFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let sessionIDFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    static func displayString(fromISO8601 rawValue: String) -> String {
        guard !rawValue.isEmpty else {
            return "未知"
        }

        let date = date(fromISO8601: rawValue)

        guard let date else {
            return rawValue
        }

        return displayFormatter.string(from: date)
    }

    static func date(fromISO8601 rawValue: String) -> Date? {
        isoFormatter.date(from: rawValue)
            ?? isoFormatterWithoutFractions.date(from: rawValue)
    }

    static func storageString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    static func sessionDate(from sessionID: String) -> Date? {
        sessionIDFormatter.date(from: String(sessionID.prefix(15)))
    }
}
