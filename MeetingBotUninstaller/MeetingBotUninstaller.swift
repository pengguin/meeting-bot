import AppKit
import Darwin
import Foundation
import SwiftUI

private enum Constants {
    static let appName = "会议纪要助手"
    static let uninstallerName = "会议纪要助手卸载器"
    static let serviceLabel = "com.pgui.feishu-meeting-bot"
    static let bundleIdentifier = "com.pgui.FeishuMeetingBotMenuBar"

    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let defaultInstallRoot = home
        .appendingPathComponent("Library/Application Support/meeting-bot", isDirectory: true)
    static let applicationSupportRoot = home
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    static let developerRoot = home
        .appendingPathComponent("Developer", isDirectory: true)
    static let legacyInstallRoots = [
        home.appendingPathComponent("Library/Application Support/meetin-bot", isDirectory: true),
        home.appendingPathComponent("Library/Application Support/feishu-meeting-bot", isDirectory: true),
        home.appendingPathComponent("meetin-bot", isDirectory: true),
        home.appendingPathComponent("meeting-bot", isDirectory: true),
        home.appendingPathComponent("feishu-meeting-bot", isDirectory: true),
    ]
    static let launchAgentPlist = home
        .appendingPathComponent("Library/LaunchAgents/\(serviceLabel).plist")
    static let logsDirectory = home
        .appendingPathComponent("Library/Logs/meeting-bot", isDirectory: true)
}

private enum ItemKind: String {
    case application = "App"
    case launchAgent = "后台服务"
    case installRoot = "安装目录"
    case environment = "环境"
    case data = "数据"
}

private struct ScanItem: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let url: URL
    let kind: ItemKind
    let backupPath: String?

    init(title: String, detail: String, url: URL, kind: ItemKind, backupPath: String? = nil) {
        self.title = title
        self.detail = detail
        self.url = url.standardizedFileURL
        self.kind = kind
        self.backupPath = backupPath
        self.id = "\(kind.rawValue):\(self.url.path)"
    }
}

private struct InstallationScan {
    var applications: [ScanItem] = []
    var launchAgents: [ScanItem] = []
    var installRoots: [ScanItem] = []
    var environments: [ScanItem] = []
    var data: [ScanItem] = []

    var hasFindings: Bool {
        !applications.isEmpty || !launchAgents.isEmpty || !installRoots.isEmpty || !data.isEmpty
    }

    var allItems: [ScanItem] {
        applications + launchAgents + installRoots + environments + data
    }
}

private enum PathTools {
    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    static func isSubpath(_ child: URL, of parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        isSubpath(lhs, of: rhs) || isSubpath(rhs, of: lhs)
    }

    static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard !seen.contains(standardized.path) else {
                return nil
            }
            seen.insert(standardized.path)
            return standardized
        }
    }

    static func display(_ url: URL) -> String {
        let homePath = Constants.home.path
        let path = url.standardizedFileURL.path
        if path == homePath {
            return "~"
        }
        if path.hasPrefix(homePath + "/") {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    static func sanitizedName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        let components = value.components(separatedBy: invalid).filter { !$0.isEmpty }
        return components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum DevelopmentProtector {
    static func isProtectedInstallRoot(_ url: URL) -> Bool {
        let resolvedURL = PathTools.resolved(url)

        if let sourceRoot = currentSourceRoot(),
           PathTools.overlaps(resolvedURL, sourceRoot) {
            return true
        }

        if PathTools.isSubpath(resolvedURL, of: PathTools.resolved(Constants.developerRoot)),
           hasRepoMarkers(at: resolvedURL) {
            return true
        }

        if PathTools.isSymbolicLink(url),
           hasRepoMarkers(at: resolvedURL),
           !PathTools.isSubpath(resolvedURL, of: PathTools.resolved(Constants.applicationSupportRoot)) {
            return true
        }

        return false
    }

    private static func currentSourceRoot() -> URL? {
        let distDirectory = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL
        guard distDirectory.lastPathComponent == "dist" else {
            return nil
        }

        let root = PathTools.resolved(distDirectory.deletingLastPathComponent())
        guard hasRepoMarkers(at: root),
              !PathTools.isSubpath(root, of: PathTools.resolved(Constants.applicationSupportRoot)) else {
            return nil
        }
        return root
    }

    private static func hasRepoMarkers(at root: URL) -> Bool {
        PathTools.exists(root.appendingPathComponent(".git", isDirectory: true)) &&
            PathTools.exists(root.appendingPathComponent("bot.py")) &&
            PathTools.exists(root.appendingPathComponent("scripts/install.sh")) &&
            PathTools.exists(root.appendingPathComponent("MeetingBotMenuBarApp/build_release_app.sh"))
    }
}

private enum EnvParser {
    static func load(from root: URL) -> [String: String] {
        let envURL = root.appendingPathComponent(".env")
        guard let contents = try? String(contentsOf: envURL, encoding: .utf8) else {
            return [:]
        }

        return contents.split(separator: "\n").reduce(into: [String: String]()) { values, rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                return
            }

            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
    }

    static func resolveStorageDir(_ rawValue: String?, defaultURL: URL, installRoot: URL) -> URL {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return defaultURL.standardizedFileURL
        }

        if trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        if NSString(string: trimmed).isAbsolutePath {
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }
        return installRoot.appendingPathComponent(trimmed, isDirectory: true).standardizedFileURL
    }
}

private enum InstallationScanner {
    static func scan() -> InstallationScan {
        let installRoots = findInstallRoots()
        var result = InstallationScan()
        result.installRoots = installRoots.map {
            ScanItem(
                title: "安装目录",
                detail: PathTools.display($0),
                url: $0,
                kind: .installRoot
            )
        }
        result.launchAgents = findLaunchAgents()
        result.applications = findApplications(installRoots: installRoots)
        result.environments = findEnvironmentItems(in: installRoots)
        result.data = findDataItems(in: installRoots)
        return result
    }

    private static func findInstallRoots() -> [URL] {
        var candidates = [Constants.defaultInstallRoot] + Constants.legacyInstallRoots

        if PathTools.exists(Constants.launchAgentPlist),
           let launchAgentRoots = rootsFromLaunchAgent(Constants.launchAgentPlist) {
            candidates.append(contentsOf: launchAgentRoots)
        }

        return PathTools.unique(candidates)
            .filter(PathTools.exists)
            .filter { !DevelopmentProtector.isProtectedInstallRoot($0) }
    }

    private static func rootsFromLaunchAgent(_ plistURL: URL) -> [URL]? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }

        var roots: [URL] = []
        if let workingDirectory = plist["WorkingDirectory"] as? String, !workingDirectory.isEmpty {
            roots.append(URL(fileURLWithPath: workingDirectory, isDirectory: true))
        }
        if let arguments = plist["ProgramArguments"] as? [String] {
            for argument in arguments where argument.hasSuffix("/start_bot.sh") {
                roots.append(URL(fileURLWithPath: argument).deletingLastPathComponent())
            }
        }
        return roots
    }

    private static func findLaunchAgents() -> [ScanItem] {
        guard PathTools.exists(Constants.launchAgentPlist) else {
            return []
        }
        return [
            ScanItem(
                title: "后台服务 LaunchAgent",
                detail: PathTools.display(Constants.launchAgentPlist),
                url: Constants.launchAgentPlist,
                kind: .launchAgent
            )
        ]
    }

    private static func findApplications(installRoots: [URL]) -> [ScanItem] {
        var candidates: [URL] = [
            URL(fileURLWithPath: "/Applications/\(Constants.appName).app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Feishu Meeting Bot.app", isDirectory: true),
            Constants.home.appendingPathComponent("Applications/\(Constants.appName).app", isDirectory: true),
            Constants.home.appendingPathComponent("Applications/Feishu Meeting Bot.app", isDirectory: true),
        ]

        for root in installRoots {
            candidates.append(root.appendingPathComponent("dist/\(Constants.appName).app", isDirectory: true))
        }

        for applicationFolder in [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            Constants.home.appendingPathComponent("Applications", isDirectory: true),
        ] where PathTools.exists(applicationFolder) {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: applicationFolder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children where child.pathExtension == "app" {
                if isMeetingBotApplication(child) {
                    candidates.append(child)
                }
            }
        }

        return PathTools.unique(candidates)
            .filter(PathTools.exists)
            .filter { !PathTools.isSubpath(Bundle.main.bundleURL, of: $0) }
            .map {
                ScanItem(
                    title: applicationTitle($0),
                    detail: PathTools.display($0),
                    url: $0,
                    kind: .application
                )
            }
    }

    private static func isMeetingBotApplication(_ url: URL) -> Bool {
        guard PathTools.exists(url) else {
            return false
        }
        if url.lastPathComponent == "\(Constants.appName).app" || url.lastPathComponent == "Feishu Meeting Bot.app" {
            return true
        }
        guard let bundle = Bundle(url: url) else {
            return false
        }
        if bundle.bundleIdentifier == Constants.bundleIdentifier {
            return true
        }
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        return displayName == Constants.appName || bundleName == Constants.appName
    }

    private static func applicationTitle(_ url: URL) -> String {
        guard let bundle = Bundle(url: url),
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            return url.deletingPathExtension().lastPathComponent
        }
        return "\(url.deletingPathExtension().lastPathComponent) \(version)"
    }

    private static func findEnvironmentItems(in roots: [URL]) -> [ScanItem] {
        var items: [ScanItem] = []
        for root in roots {
            appendExisting(
                &items,
                title: "Python 虚拟环境",
                detail: "\(PathTools.display(root))/.venv",
                url: root.appendingPathComponent(".venv", isDirectory: true),
                kind: .environment
            )
            appendExisting(
                &items,
                title: "独立 Python 运行时",
                detail: "\(PathTools.display(root))/runtime/python",
                url: root.appendingPathComponent("runtime/python", isDirectory: true),
                kind: .environment
            )
            appendExisting(
                &items,
                title: "uv 运行时管理器",
                detail: "\(PathTools.display(root))/runtime/uv",
                url: root.appendingPathComponent("runtime/uv", isDirectory: true),
                kind: .environment
            )
            appendExisting(
                &items,
                title: "运行时缓存",
                detail: "\(PathTools.display(root))/runtime/cache",
                url: root.appendingPathComponent("runtime/cache", isDirectory: true),
                kind: .environment
            )
            appendExisting(
                &items,
                title: "离线依赖缓存",
                detail: "\(PathTools.display(root))/wheelhouse",
                url: root.appendingPathComponent("wheelhouse", isDirectory: true),
                kind: .environment
            )
        }
        return uniqueItems(items)
    }

    private static func findDataItems(in roots: [URL]) -> [ScanItem] {
        var items: [ScanItem] = []

        for root in roots {
            let env = EnvParser.load(from: root)
            let defaultRecordings = root.appendingPathComponent("downloads", isDirectory: true)
            let defaultMeetings = root.appendingPathComponent("sessions", isDirectory: true)
            let recordings = EnvParser.resolveStorageDir(
                env["RECORDINGS_DIR"],
                defaultURL: defaultRecordings,
                installRoot: root
            )
            let meetings = EnvParser.resolveStorageDir(
                env["MEETING_OUTPUT_DIR"],
                defaultURL: defaultMeetings,
                installRoot: root
            )

            appendExisting(
                &items,
                title: "本地配置",
                detail: "\(PathTools.display(root))/.env",
                url: root.appendingPathComponent(".env"),
                kind: .data,
                backupPath: "配置/.env"
            )
            appendDataDirectory(
                &items,
                title: "录音和上传材料",
                url: defaultRecordings,
                backupName: "downloads"
            )
            appendDataDirectory(
                &items,
                title: "会议纪要",
                url: defaultMeetings,
                backupName: "sessions"
            )
            appendDataDirectory(
                &items,
                title: "录音和上传材料（自定义位置）",
                url: recordings,
                backupName: "custom-data/\(PathTools.sanitizedName(recordings.lastPathComponent.isEmpty ? "recordings" : recordings.lastPathComponent))"
            )
            appendDataDirectory(
                &items,
                title: "会议纪要（自定义位置）",
                url: meetings,
                backupName: "custom-data/\(PathTools.sanitizedName(meetings.lastPathComponent.isEmpty ? "sessions" : meetings.lastPathComponent))"
            )
            appendDataDirectory(
                &items,
                title: "会议库和模板",
                url: root.appendingPathComponent("library", isDirectory: true),
                backupName: "library"
            )
            appendExisting(
                &items,
                title: "最近会议索引",
                detail: "\(PathTools.display(root))/latest_session.txt",
                url: root.appendingPathComponent("latest_session.txt"),
                kind: .data,
                backupPath: "latest_session.txt"
            )
            appendDataDirectory(
                &items,
                title: "旧版本地日志",
                url: root.appendingPathComponent("logs", isDirectory: true),
                backupName: "logs/install-root-logs"
            )
        }

        appendDataDirectory(&items, title: "运行日志", url: Constants.logsDirectory, backupName: "logs")
        return uniqueItems(items)
    }

    private static func appendDataDirectory(
        _ items: inout [ScanItem],
        title: String,
        url: URL,
        backupName: String
    ) {
        appendExisting(
            &items,
            title: title,
            detail: PathTools.display(url),
            url: url,
            kind: .data,
            backupPath: backupName
        )
    }

    private static func appendExisting(
        _ items: inout [ScanItem],
        title: String,
        detail: String,
        url: URL,
        kind: ItemKind,
        backupPath: String? = nil
    ) {
        guard PathTools.exists(url) else {
            return
        }
        items.append(ScanItem(title: title, detail: detail, url: url, kind: kind, backupPath: backupPath))
    }

    private static func uniqueItems(_ items: [ScanItem]) -> [ScanItem] {
        var seen = Set<String>()
        return items.filter { item in
            guard !seen.contains(item.url.path) else {
                return false
            }
            seen.insert(item.url.path)
            return true
        }
    }
}

@MainActor
private final class UninstallerStore: ObservableObject {
    @Published var scan = InstallationScanner.scan()
    @Published var deleteEnvironment = true
    @Published var deleteData = false
    @Published var dataDestination = UninstallerStore.defaultDataDestination()
    @Published var operationLog: [String] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var completedMessage: String?
    @Published var showConfirmation = false

    var canUninstall: Bool {
        scan.hasFindings && !isWorking && (deleteData || destinationIsUsable)
    }

    var destinationIsUsable: Bool {
        !dataDestination.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func refresh() {
        scan = InstallationScanner.scan()
        operationLog = []
        errorMessage = nil
        completedMessage = nil
    }

    func chooseDataDestination() {
        let panel = NSOpenPanel()
        panel.title = "选择数据保留位置"
        panel.message = "卸载前会把配置、录音、纪要、会议库和日志移动到这里。"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = dataDestination.deletingLastPathComponent()
        if panel.runModal() == .OK, let selectedURL = panel.url {
            dataDestination = selectedURL.standardizedFileURL
        }
    }

    func uninstall() {
        guard canUninstall else {
            return
        }

        let options = UninstallOptions(
            deleteEnvironment: deleteEnvironment,
            deleteData: deleteData,
            dataDestination: dataDestination
        )
        let currentScan = scan
        isWorking = true
        errorMessage = nil
        completedMessage = nil
        operationLog = ["开始卸载..."]

        Task.detached {
            let runner = UninstallRunner(scan: currentScan, options: options)
            do {
                let logs = try runner.run()
                await MainActor.run {
                    self.operationLog = logs
                    self.completedMessage = "卸载流程已完成。"
                    self.isWorking = false
                    self.scan = InstallationScanner.scan()
                }
            } catch {
                await MainActor.run {
                    self.operationLog = runner.logs
                    self.errorMessage = error.localizedDescription
                    self.isWorking = false
                    self.scan = InstallationScanner.scan()
                }
            }
        }
    }

    static func defaultDataDestination() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return Constants.home
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("会议纪要助手保留数据-\(formatter.string(from: Date()))", isDirectory: true)
            .standardizedFileURL
    }
}

private struct UninstallOptions {
    let deleteEnvironment: Bool
    let deleteData: Bool
    let dataDestination: URL
}

private final class UninstallRunner {
    private let scan: InstallationScan
    private let options: UninstallOptions
    private let fileManager = FileManager.default
    private var failureCount = 0
    private(set) var logs: [String] = []

    init(scan: InstallationScan, options: UninstallOptions) {
        self.scan = scan
        self.options = options
    }

    func run() throws -> [String] {
        terminateRunningApplication()
        removeLaunchAgent()

        if options.deleteData {
            removeItems(scan.data, label: "数据")
        } else {
            try preserveData()
        }

        if options.deleteEnvironment {
            removeItems(scan.environments, label: "环境")
        } else if !scan.environments.isEmpty {
            log("保留 Python 环境和依赖缓存。")
        }

        removeItems(scan.applications, label: "App")
        try removeInstallRoots()
        if failureCount > 0 {
            throw UninstallError.partialFailure("有 \(failureCount) 个项目未能删除，请查看日志中的具体路径。")
        }
        log("完成。")
        return logs
    }

    private func terminateRunningApplication() {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Constants.bundleIdentifier)
        guard !runningApps.isEmpty else {
            return
        }

        for app in runningApps {
            if app.terminate() {
                log("已请求退出正在运行的会议纪要助手。")
            } else {
                log("未能自动退出正在运行的会议纪要助手，请手动退出后再次卸载。")
            }
        }
        Thread.sleep(forTimeInterval: 1.0)
    }

    private func removeLaunchAgent() {
        let uid = String(getuid())
        let bootout = Shell.run("/bin/launchctl", ["bootout", "gui/\(uid)", Constants.launchAgentPlist.path])
        if bootout.exitCode == 0 {
            log("已停止后台服务。")
        } else if PathTools.exists(Constants.launchAgentPlist) {
            log("后台服务可能未在运行，继续移除配置。")
        }

        _ = Shell.run("/bin/launchctl", ["disable", "gui/\(uid)/\(Constants.serviceLabel)"])
        removeURL(Constants.launchAgentPlist, title: "后台服务配置")
    }

    private func preserveData() throws {
        guard !scan.data.isEmpty else {
            log("未发现需要保留的数据文件。")
            return
        }

        let destination = options.dataDestination.standardizedFileURL
        try validateDataDestination(destination)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        var manifestLines = [
            "会议纪要助手卸载保留数据",
            "生成时间：\(Date())",
            "",
        ]

        for item in scan.data where PathTools.exists(item.url) {
            let backupPath = item.backupPath ?? item.url.lastPathComponent
            let target = try availableDestination(for: destination.appendingPathComponent(backupPath))
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try moveItem(from: item.url, to: target)
            log("已保留 \(item.title)：\(PathTools.display(target))")
            manifestLines.append("- \(item.title)")
            manifestLines.append("  原位置：\(item.url.path)")
            manifestLines.append("  新位置：\(target.path)")
        }

        let manifest = destination.appendingPathComponent("保留数据说明.txt")
        try manifestLines.joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)
        log("数据保留说明已写入：\(PathTools.display(manifest))")
    }

    private func validateDataDestination(_ destination: URL) throws {
        for root in scan.installRoots.map(\.url) where PathTools.isSubpath(destination, of: root) {
            throw UninstallError.invalidDestination("数据保留位置不能放在安装目录内：\(PathTools.display(root))")
        }
        for item in scan.data where PathTools.isSubpath(destination, of: item.url) {
            throw UninstallError.invalidDestination("数据保留位置不能放在待移动的数据目录内部：\(PathTools.display(item.url))")
        }
    }

    private func availableDestination(for target: URL) throws -> URL {
        var candidate = target.standardizedFileURL
        guard PathTools.exists(candidate) else {
            return candidate
        }

        let parent = candidate.deletingLastPathComponent()
        let filename = candidate.lastPathComponent
        let split = filename.range(of: ".", options: .backwards)
        let hasRealExtension = split.map { $0.lowerBound != filename.startIndex } ?? false
        let base = hasRealExtension ? String(filename[..<split!.lowerBound]) : filename
        let ext = hasRealExtension ? String(filename[split!.upperBound...]) : ""

        for index in 2...200 {
            let name = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = parent.appendingPathComponent(name)
            if !PathTools.exists(candidate) {
                return candidate
            }
        }

        throw UninstallError.fileConflict("无法为 \(target.path) 生成可用的保留文件名。")
    }

    private func moveItem(from source: URL, to target: URL) throws {
        do {
            try fileManager.moveItem(at: source, to: target)
        } catch {
            try fileManager.copyItem(at: source, to: target)
            try fileManager.removeItem(at: source)
        }
    }

    private func removeItems(_ items: [ScanItem], label: String) {
        let urls = PathTools.unique(items.map(\.url))
        for url in urls {
            removeURL(url, title: label)
        }
    }

    private func removeInstallRoots() throws {
        let retainedEnvironment = options.deleteEnvironment ? [] : scan.environments.map(\.url)

        for root in scan.installRoots.map(\.url) where PathTools.exists(root) {
            if retainedEnvironment.filter({ PathTools.isSubpath($0, of: root) }).isEmpty {
                removeURL(root, title: "安装目录")
                continue
            }

            let children = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )) ?? []

            for child in children {
                if retainedEnvironment.contains(where: { PathTools.isSubpath($0, of: child) || PathTools.isSubpath(child, of: $0) }) {
                    log("保留环境目录：\(PathTools.display(child))")
                    continue
                }
                removeURL(child, title: "安装目录内容")
            }

            if directoryIsEmpty(root) {
                removeURL(root, title: "安装目录")
            } else {
                log("安装目录仍保留，因为其中包含用户选择保留的环境文件：\(PathTools.display(root))")
            }
        }
    }

    private func directoryIsEmpty(_ url: URL) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return contents.isEmpty
    }

    private func removeURL(_ url: URL, title: String) {
        guard PathTools.exists(url) else {
            return
        }

        do {
            try fileManager.removeItem(at: url)
            log("已删除 \(title)：\(PathTools.display(url))")
        } catch {
            failureCount += 1
            log("删除失败 \(PathTools.display(url))：\(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        logs.append(message)
    }
}

private enum Shell {
    static func run(_ executable: String, _ arguments: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

private enum UninstallError: LocalizedError {
    case invalidDestination(String)
    case fileConflict(String)
    case partialFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidDestination(let message), .fileConflict(let message), .partialFailure(let message):
            return message
        }
    }
}

@main
private struct MeetingBotUninstallerApp: App {
    var body: some Scene {
        WindowGroup {
            UninstallerView()
                .frame(minWidth: 760, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct UninstallerView: View {
    @StateObject private var store = UninstallerStore()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !store.scan.hasFindings {
                        emptyState
                    } else {
                        foundSections
                        optionsSection
                    }
                    resultSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .alert("确认卸载会议纪要助手？", isPresented: $store.showConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认卸载", role: .destructive) {
                store.uninstall()
            }
        } message: {
            Text(confirmMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(Constants.uninstallerName)
                    .font(.title2.weight(.semibold))
                Text("扫描本机安装的 App、后台服务、安装目录、Python 环境、会议数据和日志。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .disabled(store.isWorking)
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("未找到会议纪要助手安装", systemImage: "checkmark.circle")
                .font(.headline)
            Text("常见位置中没有发现 App、LaunchAgent 或安装目录。可以重新扫描，或确认当前用户是否就是安装时使用的 macOS 用户。")
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var foundSections: some View {
        VStack(alignment: .leading, spacing: 14) {
            itemSection(title: "App", icon: "app.dashed", items: store.scan.applications)
            itemSection(title: "后台服务", icon: "gearshape.2", items: store.scan.launchAgents)
            itemSection(title: "安装目录", icon: "externaldrive", items: store.scan.installRoots)
            itemSection(title: "Python 环境和依赖缓存", icon: "terminal", items: store.scan.environments)
            itemSection(title: "数据和日志", icon: "folder", items: store.scan.data)
        }
    }

    private func itemSection(title: String, icon: String, items: [ScanItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            if items.isEmpty {
                Text("未发现")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 28)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.callout.weight(.medium))
                                Text(item.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                        if item.id != items.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("卸载选项")
                .font(.headline)

            Toggle(isOn: $store.deleteEnvironment) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("删除 Python 环境和依赖缓存")
                    Text("包括 `.venv`、托管 Python、uv 和离线依赖缓存；不会删除系统级 Homebrew、ffmpeg、LibreOffice 或 Codex CLI。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Toggle(isOn: $store.deleteData) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("删除会议数据、配置和日志")
                    Text("关闭时会先把 `.env`、录音、纪要、会议库和日志移动到新的保存位置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            if !store.deleteData {
                VStack(alignment: .leading, spacing: 8) {
                    Text("数据保留位置")
                        .font(.callout.weight(.medium))
                    HStack(spacing: 8) {
                        Text(store.dataDestination.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.background, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(.quaternary, lineWidth: 1)
                            )
                        Button {
                            store.chooseDataDestination()
                        } label: {
                            Label("选择", systemImage: "folder")
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let completedMessage = store.completedMessage {
                Label(completedMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let errorMessage = store.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !store.operationLog.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(store.operationLog.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(store.isWorking ? "正在卸载..." : footerSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("退出") {
                NSApp.terminate(nil)
            }
            .disabled(store.isWorking)
            Button(role: .destructive) {
                store.showConfirmation = true
            } label: {
                Label("开始卸载", systemImage: "trash")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!store.canUninstall)
        }
        .padding(24)
    }

    private var footerSummary: String {
        guard store.scan.hasFindings else {
            return "没有可卸载项目"
        }
        return "将移除 App、后台服务和安装文件"
    }

    private var confirmMessage: String {
        var parts = ["将停止后台服务并删除会议纪要助手 App 与安装文件。"]
        parts.append(store.deleteEnvironment ? "Python 环境和依赖缓存会被删除。" : "Python 环境和依赖缓存会保留在原安装目录。")
        if store.deleteData {
            parts.append("会议数据、配置和日志会被删除。")
        } else {
            parts.append("会议数据、配置和日志会移动到：\(store.dataDestination.path)")
        }
        return parts.joined(separator: "\n")
    }
}
