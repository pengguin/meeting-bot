import Combine
import Foundation
import UserNotifications

private struct RuntimeStatusReadResult {
    let status: RuntimeStatus?
    let errorMessage: String?
}

private struct MeetingEventsReadResult {
    let recentMeetings: [MeetingDoneEvent]
    let processedEventFiles: Set<String>
    let newEvents: [MeetingDoneEvent]
    let errorMessage: String?
}

final class BotRuntimeStore: ObservableObject {
    static let notificationsEnabledKey = "notificationsEnabled"

    @Published private(set) var launchStatus: LaunchAgentStatus = .unknown
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var runtimeStatus: RuntimeStatus?
    @Published private(set) var recentMeetings: [MeetingDoneEvent] = []
    @Published private(set) var environmentChecks: [EnvironmentCheck] = []
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isServiceActionRunning = false

    private static let processedEventsKey = "processedMeetingDoneEvents"

    private let launchAgentManager = LaunchAgentManager()
    private let notificationCenter = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var processedEventFiles: Set<String>
    private var refreshTimer: Timer?
    private var lastServiceActionError: String?
    private var lastEnvironmentCheckDate: Date?
    private let refreshQueue = DispatchQueue(label: "meeting-bot.runtime.refresh", qos: .utility)
    private var isRefreshInProgress = false
    private var needsRefreshAfterCurrent = false

    init() {
        processedEventFiles = Set(defaults.stringArray(forKey: Self.processedEventsKey) ?? [])
        refresh()

        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    deinit {
        refreshTimer?.invalidate()
    }

    var menuBarSymbol: String {
        if launchStatus == .missing || launchStatus == .stopped {
            return "exclamationmark.triangle.fill"
        }

        switch runtimeStatus?.taskStatus {
        case "processing":
            return "waveform.circle"
        case "done":
            return "checkmark.circle.fill"
        case "error":
            return "exclamationmark.triangle.fill"
        default:
            return "waveform"
        }
    }

    var latestMeeting: MeetingDoneEvent? {
        recentMeetings.first
    }

    var latestPDFURL: URL? {
        latestMeeting?.pdfURL ?? runtimeStatus?.latestPDFURL
    }

    var latestDOCXURL: URL? {
        latestMeeting?.docxURL ?? runtimeStatus?.latestDOCXURL
    }

    var latestHTMLURL: URL? {
        latestMeeting?.htmlURL ?? runtimeStatus?.latestHTMLURL
    }

    var latestMDURL: URL? {
        latestMeeting?.mdURL ?? runtimeStatus?.latestMDURL
    }

    var latestSessionURL: URL? {
        latestMeeting?.sessionURL ?? runtimeStatus?.sessionURL
    }

    var visibleErrorMessage: String? {
        lastServiceActionError ?? lastErrorMessage
    }

    var healthyEnvironmentCount: Int {
        environmentChecks.filter(\.isHealthy).count
    }

    var environmentSummary: String {
        guard !environmentChecks.isEmpty else {
            return "未检查"
        }

        return "\(healthyEnvironmentCount)/\(environmentChecks.count) 正常"
    }

    var unhealthyEnvironmentChecks: [EnvironmentCheck] {
        environmentChecks.filter { !$0.isHealthy }
    }

    func refresh() {
        if isRefreshInProgress {
            needsRefreshAfterCurrent = true
            return
        }

        let now = Date()
        let shouldCheckEnvironment = lastEnvironmentCheckDate.map { now.timeIntervalSince($0) >= 120 } ?? true
        let shouldReadLaunchAtLogin = !isServiceActionRunning
        let processedEventFilesSnapshot = processedEventFiles
        isRefreshInProgress = true

        refreshQueue.async { [weak self] in
            guard let self else {
                return
            }

            let launchStatus = self.launchAgentManager.status()
            let launchAtLoginEnabled = shouldReadLaunchAtLogin
                ? self.launchAgentManager.isLaunchAtLoginEnabled()
                : nil
            let environmentChecks = shouldCheckEnvironment
                ? EnvironmentHealthChecker.run()
                : nil
            let runtimeStatusResult = Self.readRuntimeStatus()
            let meetingEventsResult = Self.readMeetingEvents(
                processedEventFiles: processedEventFilesSnapshot
            )

            DispatchQueue.main.async {
                self.launchStatus = launchStatus
                if let launchAtLoginEnabled {
                    self.launchAtLoginEnabled = launchAtLoginEnabled
                }
                if let environmentChecks {
                    self.environmentChecks = environmentChecks
                    self.lastEnvironmentCheckDate = now
                }
                self.runtimeStatus = runtimeStatusResult.status
                self.recentMeetings = meetingEventsResult.recentMeetings
                self.processedEventFiles = meetingEventsResult.processedEventFiles
                self.defaults.set(
                    Array(meetingEventsResult.processedEventFiles).sorted(),
                    forKey: Self.processedEventsKey
                )
                self.lastErrorMessage = runtimeStatusResult.errorMessage
                    ?? meetingEventsResult.errorMessage
                self.lastRefreshDate = now

                for event in meetingEventsResult.newEvents.sorted(by: Self.isOlderEvent) where self.notificationsEnabled {
                    self.sendNotification(for: event)
                }

                self.isRefreshInProgress = false
                if self.needsRefreshAfterCurrent {
                    self.needsRefreshAfterCurrent = false
                    self.refresh()
                }
            }
        }
    }

    func startService() {
        runServiceAction { [launchAgentManager] in
            launchAgentManager.start()
        }
    }

    func stopService() {
        runServiceAction { [launchAgentManager] in
            launchAgentManager.stop()
        }
    }

    func restartService() {
        runServiceAction { [launchAgentManager] in
            launchAgentManager.restart()
        }
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard launchAtLoginEnabled != enabled else {
            return
        }

        launchAtLoginEnabled = enabled
        runServiceAction { [launchAgentManager] in
            launchAgentManager.setLaunchAtLoginEnabled(enabled)
        }
    }

    func openProjectDirectory() {
        FileOpener.open(AppPaths.projectRoot)
    }

    func openSessionsDirectory() {
        FileOpener.open(AppPaths.sessionsDirectory)
    }

    func openLogsDirectory() {
        FileOpener.open(AppPaths.logsDirectory)
    }

    func openErrorLog() {
        FileOpener.open(AppPaths.exists(AppPaths.errorLog) ? AppPaths.errorLog : nil)
    }

    func openLatestSession() {
        FileOpener.open(latestSessionURL)
    }

    func openLatestPDF() {
        FileOpener.open(latestPDFURL)
    }

    func openLatestDOCX() {
        FileOpener.open(latestDOCXURL)
    }

    func openLatestHTML() {
        FileOpener.open(latestHTMLURL)
    }

    func openLatestMD() {
        FileOpener.open(latestMDURL)
    }

    func requestNotificationPermissionIfNeeded() {
        guard notificationsEnabled else {
            return
        }

        notificationCenter.getNotificationSettings { [notificationCenter] settings in
            guard settings.authorizationStatus == .notDetermined else {
                return
            }

            notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    print("[Notification] 授权请求失败：\(error.localizedDescription)")
                }
                if !granted {
                    print("[Notification] 用户未开启通知权限")
                }
            }
        }
    }

    private var notificationsEnabled: Bool {
        if defaults.object(forKey: Self.notificationsEnabledKey) == nil {
            return true
        }

        return defaults.bool(forKey: Self.notificationsEnabledKey)
    }

    private func runServiceAction(_ action: @escaping () -> LaunchAgentCommandResult) {
        guard !isServiceActionRunning else {
            return
        }

        isServiceActionRunning = true
        lastServiceActionError = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = action()

            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if !result.succeeded {
                    let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastServiceActionError = trimmedOutput.isEmpty ? "服务操作失败" : trimmedOutput
                }

                self.isServiceActionRunning = false
                self.refresh()
            }
        }
    }

    private static func readRuntimeStatus() -> RuntimeStatusReadResult {
        guard AppPaths.exists(AppPaths.statusFile) else {
            return RuntimeStatusReadResult(status: nil, errorMessage: nil)
        }

        do {
            let data = try Data(contentsOf: AppPaths.statusFile)
            let status = try JSONDecoder().decode(RuntimeStatus.self, from: data)
            return RuntimeStatusReadResult(status: status, errorMessage: nil)
        } catch {
            return RuntimeStatusReadResult(
                status: nil,
                errorMessage: "状态文件读取失败：\(error.localizedDescription)"
            )
        }
    }

    private static func readMeetingEvents(processedEventFiles: Set<String>) -> MeetingEventsReadResult {
        guard AppPaths.exists(AppPaths.eventsDirectory) else {
            return MeetingEventsReadResult(
                recentMeetings: [],
                processedEventFiles: processedEventFiles,
                newEvents: [],
                errorMessage: nil
            )
        }

        do {
            let eventFiles = try FileManager.default.contentsOfDirectory(
                at: AppPaths.eventsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter {
                $0.lastPathComponent.hasPrefix("meeting_done_")
                    && $0.pathExtension == "json"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            let relevantEventFiles = Array(eventFiles.suffix(200))
            var nextProcessedEventFiles = processedEventFiles
            nextProcessedEventFiles.formIntersection(Set(relevantEventFiles.map(\.lastPathComponent)))

            var decodedEvents: [MeetingDoneEvent] = []
            var newEvents: [MeetingDoneEvent] = []

            for eventFile in relevantEventFiles {
                do {
                    let data = try Data(contentsOf: eventFile)
                    var event = try JSONDecoder().decode(MeetingDoneEvent.self, from: data)

                    guard event.event == "meeting_done" else {
                        continue
                    }

                    event.eventFileName = eventFile.lastPathComponent
                    decodedEvents.append(event)

                    if !nextProcessedEventFiles.contains(eventFile.lastPathComponent) {
                        newEvents.append(event)
                        nextProcessedEventFiles.insert(eventFile.lastPathComponent)
                    }
                } catch {
                    print("[Runtime Event] 忽略无法解析的事件：\(eventFile.lastPathComponent) \(error)")
                }
            }

            let recentMeetings = Array(
                decodedEvents
                    .sorted(by: Self.isNewerEvent)
                    .prefix(3)
            )

            return MeetingEventsReadResult(
                recentMeetings: recentMeetings,
                processedEventFiles: nextProcessedEventFiles,
                newEvents: newEvents,
                errorMessage: nil
            )
        } catch {
            return MeetingEventsReadResult(
                recentMeetings: [],
                processedEventFiles: processedEventFiles,
                newEvents: [],
                errorMessage: "事件目录读取失败：\(error.localizedDescription)"
            )
        }
    }

    private func loadRuntimeStatus() {
        guard AppPaths.exists(AppPaths.statusFile) else {
            runtimeStatus = nil
            return
        }

        do {
            let data = try Data(contentsOf: AppPaths.statusFile)
            runtimeStatus = try JSONDecoder().decode(RuntimeStatus.self, from: data)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = "状态文件读取失败：\(error.localizedDescription)"
        }
    }

    private func scanMeetingEvents() {
        guard AppPaths.exists(AppPaths.eventsDirectory) else {
            return
        }

        do {
            let eventFiles = try FileManager.default.contentsOfDirectory(
                at: AppPaths.eventsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter {
                $0.lastPathComponent.hasPrefix("meeting_done_")
                    && $0.pathExtension == "json"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            let relevantEventFiles = Array(eventFiles.suffix(200))
            processedEventFiles.formIntersection(Set(relevantEventFiles.map(\.lastPathComponent)))

            var decodedEvents: [MeetingDoneEvent] = []
            var newEvents: [MeetingDoneEvent] = []

            for eventFile in relevantEventFiles {
                do {
                    let data = try Data(contentsOf: eventFile)
                    var event = try JSONDecoder().decode(MeetingDoneEvent.self, from: data)

                    guard event.event == "meeting_done" else {
                        continue
                    }

                    event.eventFileName = eventFile.lastPathComponent
                    decodedEvents.append(event)

                    if !processedEventFiles.contains(eventFile.lastPathComponent) {
                        newEvents.append(event)
                        processedEventFiles.insert(eventFile.lastPathComponent)
                    }
                } catch {
                    print("[Runtime Event] 忽略无法解析的事件：\(eventFile.lastPathComponent) \(error)")
                }
            }

            recentMeetings = Array(
                decodedEvents
                    .sorted(by: Self.isNewerEvent)
                    .prefix(3)
            )

            defaults.set(Array(processedEventFiles).sorted(), forKey: Self.processedEventsKey)

            guard !newEvents.isEmpty else {
                return
            }

            for event in newEvents.sorted(by: Self.isOlderEvent) where notificationsEnabled {
                sendNotification(for: event)
            }
        } catch {
            lastErrorMessage = "事件目录读取失败：\(error.localizedDescription)"
        }
    }

    private static func isNewerEvent(_ lhs: MeetingDoneEvent, _ rhs: MeetingDoneEvent) -> Bool {
        let lhsDate = lhs.createdDate ?? .distantPast
        let rhsDate = rhs.createdDate ?? .distantPast

        if lhsDate == rhsDate {
            return lhs.eventFileName > rhs.eventFileName
        }

        return lhsDate > rhsDate
    }

    private static func isOlderEvent(_ lhs: MeetingDoneEvent, _ rhs: MeetingDoneEvent) -> Bool {
        let lhsDate = lhs.createdDate ?? .distantPast
        let rhsDate = rhs.createdDate ?? .distantPast

        if lhsDate == rhsDate {
            return lhs.eventFileName < rhs.eventFileName
        }

        return lhsDate < rhsDate
    }

    private func sendNotification(for event: MeetingDoneEvent) {
        let content = UNMutableNotificationContent()
        content.title = "会议纪要已生成"
        content.body = event.version == "named"
            ? "实名版 PDF、DOCX、HTML 与 MD 已输出，可打开查看。"
            : "匿名版会议纪要已生成，可继续补充说话人身份。"
        content.sound = .default
        content.userInfo = [
            "summary_pdf": event.summaryPDF,
            "summary_docx": event.summaryDOCX,
            "summary_html": event.summaryHTML,
            "summary_md": event.summaryMD,
            "session_dir": event.sessionDirectory,
        ]

        let addNotification = { [notificationCenter] in
            let request = UNNotificationRequest(
                identifier: "meeting_done_\(event.id)",
                content: content,
                trigger: nil
            )

            notificationCenter.add(request) { error in
                if let error {
                    print("[Notification] 发送失败：\(error.localizedDescription)")
                }
            }
        }

        notificationCenter.getNotificationSettings { [notificationCenter] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                addNotification()
            case .notDetermined:
                notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        print("[Notification] 授权请求失败：\(error.localizedDescription)")
                    }
                    if granted {
                        addNotification()
                    }
                }
            case .denied:
                print("[Notification] 通知权限未开启")
            @unknown default:
                print("[Notification] 未知通知权限状态")
            }
        }
    }
}
