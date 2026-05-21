import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @ObservedObject var runtimeStore: BotRuntimeStore
    @ObservedObject var libraryStore: MeetingLibraryStore
    @ObservedObject var templateStore: MeetingTemplateCatalogStore
    let openTranscriptWindow: (MeetingRecord) -> Void
    let openNewMeetingWindow: () -> Void
    let openSettingsWindow: () -> Void
    @State private var selectedTab: MainWindowTabKind = .library
    @AppStorage("preferredMainColorScheme") private var preferredMainColorScheme = "system"
    @AppStorage("showOverviewTab") private var showOverviewTab = false
    @AppStorage("mainTabOrder") private var mainTabOrderRaw = "library,overview"

    private var visibleTabs: [MainWindowTabKind] {
        MainWindowTabKind.decodeOrder(mainTabOrderRaw)
            .filter { $0 == .library || showOverviewTab }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(visibleTabs) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Label(tab.title, systemImage: tab.systemImage)
                            .font(.headline)
                            .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minWidth: 120, minHeight: 38)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        selectedTab == tab
                                            ? Color.accentColor.opacity(0.14)
                                            : Color.clear
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    preferredMainColorScheme = nextAppearanceMode(after: preferredMainColorScheme)
                } label: {
                    Label(appearanceTitle, systemImage: appearanceSystemImage)
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .help("切换显示模式")

                Button {
                    openSettingsWindow()
                } label: {
                    Label("设置", systemImage: "gearshape")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            Group {
                switch selectedTab {
                case .overview:
                    MainOverviewView(
                        store: runtimeStore,
                        libraryStore: libraryStore,
                        selectedTab: $selectedTab
                    )
                case .library:
                    MeetingLibraryView(
                        store: libraryStore,
                        templateStore: templateStore,
                        openTranscriptWindow: openTranscriptWindow,
                        openNewMeetingWindow: openNewMeetingWindow
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            mainStatusBar
        }
        .frame(minWidth: 1080, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(resolvedColorScheme)
        .onAppear {
            normalizeSelection()
            AppAppearance.synchronizeWindows(for: preferredMainColorScheme)
        }
        .onChange(of: showOverviewTab) { _, _ in
            normalizeSelection()
        }
        .onChange(of: mainTabOrderRaw) { _, _ in
            normalizeSelection()
        }
        .onChange(of: preferredMainColorScheme) { _, newValue in
            AppAppearance.synchronizeWindows(for: newValue)
        }
    }

    private func normalizeSelection() {
        if !visibleTabs.contains(selectedTab) {
            selectedTab = visibleTabs.first ?? .library
        }
    }

    @ViewBuilder
    private var mainStatusBar: some View {
        HStack(spacing: 10) {
            switch selectedTab {
            case .overview:
                Text("版本 \(AppVersion.current)")
            case .library:
                Button {
                    libraryStore.reload(forceScan: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新扫描 sessions")

                Text("\(libraryStore.filteredMeetings.count) / \(libraryStore.meetings.count) 场会议")
            }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var resolvedColorScheme: ColorScheme? {
        AppAppearance.resolvedColorScheme(for: preferredMainColorScheme)
    }

    private var appearanceTitle: String {
        switch preferredMainColorScheme {
        case "light":
            return "白天"
        case "dark":
            return "夜览"
        default:
            return "自动"
        }
    }

    private var appearanceSystemImage: String {
        switch preferredMainColorScheme {
        case "light":
            return "sun.max"
        case "dark":
            return "moon"
        default:
            return "circle.lefthalf.filled"
        }
    }

    private func nextAppearanceMode(after current: String) -> String {
        switch current {
        case "system":
            return "light"
        case "light":
            return "dark"
        default:
            return "system"
        }
    }
}

private struct MainOverviewView: View {
    @ObservedObject var store: BotRuntimeStore
    @ObservedObject var libraryStore: MeetingLibraryStore
    @Binding var selectedTab: MainWindowTabKind
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    functionPanel
                    statusPanel
                    environmentPanel
                }
                .frame(minHeight: 228)

                HStack(alignment: .top, spacing: 16) {
                    latestMeetingPanel
                    recentMeetingsPanel
                }
                .frame(minHeight: 300)
            }
            .padding(20)
        }
        .onAppear {
            store.refresh()
            libraryStore.reload()
            if notificationsEnabled {
                store.requestNotificationPermissionIfNeeded()
            }
        }
    }

    private var functionPanel: some View {
        OverviewPanel(title: "功能", accentColor: .blue) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Button {
                            store.startService()
                        } label: {
                            Label("启动", systemImage: "play.fill")
                        }

                        Button {
                            store.stopService()
                        } label: {
                            Label("停止", systemImage: "stop.fill")
                        }

                        Button {
                            store.restartService()
                        } label: {
                            Label("重启", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.launchStatus == .missing || store.isServiceActionRunning)

                    Toggle(
                        isOn: Binding(
                            get: { store.launchAtLoginEnabled },
                            set: { store.setLaunchAtLoginEnabled($0) }
                        )
                    ) {
                        Label("开机启动", systemImage: "power")
                    }
                    .disabled(store.launchStatus == .missing || store.isServiceActionRunning)
                    .toggleStyle(.checkbox)

                    Toggle(isOn: $notificationsEnabled) {
                        Label("完成后通知", systemImage: "bell")
                    }
                    .toggleStyle(.checkbox)
                }
                .frame(height: 112, alignment: .topLeading)

                Divider()

                Text("打开文件夹")
                    .font(.headline)

                HStack(spacing: 8) {
                    ShortcutButton(title: "项目", systemImage: "shippingbox") {
                        store.openProjectDirectory()
                    }
                    ShortcutButton(title: "会话", systemImage: "folder") {
                        store.openSessionsDirectory()
                    }
                    ShortcutButton(title: "日志", systemImage: "doc.plaintext") {
                        store.openLogsDirectory()
                    }
                    ShortcutButton(title: "错误", systemImage: "exclamationmark.bubble") {
                        store.openErrorLog()
                    }
                    .disabled(!AppPaths.exists(AppPaths.errorLog))
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 228, maxHeight: .infinity, alignment: .top)
    }

    private var statusPanel: some View {
        OverviewPanel(title: "状态", accentColor: .blue) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    StatusRow(
                        title: "服务",
                        value: store.launchStatus.displayName,
                        systemImage: store.launchStatus.symbolName,
                        color: store.launchStatus.tintColor
                    )

                    if let status = store.runtimeStatus {
                        StatusRow(
                            title: "任务",
                            value: status.taskDisplayName,
                            systemImage: status.taskSymbolName,
                            color: status.taskTintColor
                        )
                        StatusRow(
                            title: "阶段",
                            value: status.stageDisplayName,
                            systemImage: "point.3.connected.trianglepath.dotted",
                            color: .blue
                        )
                        StatusRow(
                            title: "更新",
                            value: status.updatedAtDisplay,
                            systemImage: "clock",
                            color: .secondary
                        )
                    } else {
                        Text("尚未读取到任务状态")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 112, alignment: .topLeading)

                Divider()

                Text(statusMessage)
                    .foregroundStyle(statusMessageColor)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 228, maxHeight: .infinity, alignment: .top)
    }

    private var latestMeetingPanel: some View {
        OverviewPanel(title: "最近一次会议", accentColor: .teal) {
            VStack(alignment: .leading, spacing: 12) {
                if let meeting = store.latestMeeting {
                    Text(meeting.titleDisplayName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)

                    HStack(spacing: 12) {
                        Label(meeting.versionDisplayName, systemImage: "doc.badge.gearshape")
                        Label(meeting.createdAtDisplay, systemImage: "calendar")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    Text("暂无会议结果")
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("纪要内容")
                    .font(.headline)

                Text(latestMeetingSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor))
                    )

                HStack(spacing: 8) {
                    let latestRecord = latestMeetingRecord
                    LibraryFileButton(title: "会议目录", systemImage: "folder", url: store.latestSessionURL)
                    LibraryFileButton(
                        title: "HTML",
                        systemImage: "safari",
                        url: latestRecord?.latestHTMLURL ?? store.latestHTMLURL,
                        isGenerating: isGeneratingExport(for: latestRecord, format: "html"),
                        generateFile: exportGenerationAction(for: latestRecord, format: "html")
                    )
                    LibraryFileButton(
                        title: "MD",
                        systemImage: "doc.plaintext",
                        url: latestRecord?.latestMDURL ?? store.latestMDURL,
                        isGenerating: isGeneratingExport(for: latestRecord, format: "md"),
                        generateFile: exportGenerationAction(for: latestRecord, format: "md")
                    )
                    LibraryFileButton(
                        title: "DOCX",
                        systemImage: "doc.text",
                        url: latestRecord?.latestDOCXURL ?? store.latestDOCXURL,
                        isGenerating: isGeneratingExport(for: latestRecord, format: "docx"),
                        generateFile: exportGenerationAction(for: latestRecord, format: "docx")
                    )
                    LibraryFileButton(
                        title: "PDF",
                        systemImage: "doc.richtext",
                        url: latestRecord?.latestPDFURL ?? store.latestPDFURL,
                        isGenerating: isGeneratingExport(for: latestRecord, format: "pdf"),
                        generateFile: exportGenerationAction(for: latestRecord, format: "pdf")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .top)
    }

    private var latestMeetingRecord: MeetingRecord? {
        let candidateSessionIDs = [
            store.latestMeeting?.sessionID,
            store.runtimeStatus?.sessionID,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        for sessionID in candidateSessionIDs {
            if let meeting = libraryStore.meetings.first(where: { $0.sessionID == sessionID }) {
                return meeting
            }
        }
        return nil
    }

    private func isGeneratingExport(for meeting: MeetingRecord?, format: String) -> Bool {
        guard let meeting else {
            return false
        }
        return libraryStore.isGeneratingExport(for: meeting, format: format)
    }

    private func exportGenerationAction(for meeting: MeetingRecord?, format: String) -> (() -> Void)? {
        guard let meeting else {
            return nil
        }
        return {
            libraryStore.generateExport(for: meeting, format: format)
        }
    }

    private var environmentPanel: some View {
        OverviewPanel(title: "运行环境", accentColor: .blue) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(store.environmentChecks) { check in
                    HStack(spacing: 10) {
                        Image(systemName: check.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(check.isHealthy ? .green : .orange)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if check.id == "ffmpeg", !check.isHealthy {
                            Button {
                                store.startService()
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.bordered)
                            .help("启动")
                            .disabled(store.launchStatus == .missing || store.isServiceActionRunning)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 228, maxHeight: .infinity, alignment: .top)
    }

    private var recentMeetingsPanel: some View {
        OverviewPanel(title: "近期会议", accentColor: .teal) {
            VStack(alignment: .leading, spacing: 10) {
                if store.recentMeetings.isEmpty {
                    Text("暂无会议结果")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.recentMeetings) { meeting in
                        Button {
                            libraryStore.selectMeeting(sessionID: meeting.sessionID)
                            selectedTab = .library
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.titleDisplayName)
                                    .lineLimit(1)
                                HStack(spacing: 10) {
                                    Text(meeting.versionDisplayName)
                                    Text(meeting.createdAtDisplay)
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .top)
    }

    private var statusMessage: String {
        if let errorMessage = store.visibleErrorMessage, !errorMessage.isEmpty {
            return errorMessage
        }

        if let message = store.runtimeStatus?.message, !message.isEmpty {
            return message
        }

        return "机器人后台服务运行中"
    }

    private var statusMessageColor: Color {
        if let errorMessage = store.visibleErrorMessage, !errorMessage.isEmpty {
            return .red
        }

        return .secondary
    }

    private var latestMeetingSummary: String {
        guard let latestMeeting = store.latestMeeting,
              let matchingMeeting = libraryStore.meetings.first(where: {
                  $0.sessionID == latestMeeting.sessionID
              }) else {
            return "暂无可显示的纪要内容。"
        }

        if !matchingMeeting.takeaway.isEmpty {
            return matchingMeeting.takeaway
        }

        return matchingMeeting.summary.isEmpty ? "暂无可显示的纪要内容。" : matchingMeeting.summary
    }
}

private struct MeetingLibraryView: View {
    private enum NavigationColumn: Hashable {
        case folders
        case meetings
    }

    @ObservedObject var store: MeetingLibraryStore
    @ObservedObject var templateStore: MeetingTemplateCatalogStore
    let openTranscriptWindow: (MeetingRecord) -> Void
    let openNewMeetingWindow: () -> Void
    @State private var isDateFilterPresented = false
    @State private var isCreatingFolder = false
    @State private var isRenamingFolder = false
    @State private var isEmptyingTrash = false
    @State private var isPermanentlyDeletingMeetings = false
    @State private var pendingFolderName = ""
    @State private var folderBeingRenamed: LibraryFolder?
    @State private var pendingPermanentDeletionMeetings: [MeetingRecord] = []
    @State private var quickLabelBeingRenamed: String?
    @State private var pendingQuickLabelName = ""
    @State private var pendingMeetingTypeChange: MeetingRecord?
    @State private var pendingMeetingTemplateID = ""
    @State private var detailDrafts: [String: MeetingDetailDraft] = [:]
    @State private var customLabelDrafts: [String: String] = [:]
    @State private var pendingMoveToNewFolderMeetingIDs: Set<String> = []
    @State private var folderPendingDeletion: LibraryFolder?
    @State private var folderPendingHardDeletion: LibraryFolder?
    @FocusState private var focusedNavigationColumn: NavigationColumn?

    var body: some View {
        HSplitView {
            sidebar
                .frame(
                    minWidth: 420,
                    idealWidth: 470,
                    maxWidth: 540,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )

            detail
                .frame(minWidth: 620, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            store.reload()
            if focusedNavigationColumn == nil {
                focusedNavigationColumn = .folders
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("搜索标题、内容、标签、备注或说话人", text: $store.searchText)
                    .textFieldStyle(.roundedBorder)

                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Text("标签")
                            .foregroundStyle(.secondary)
                        Menu {
                            Button("全部") {
                                store.selectedLabels.removeAll()
                            }
                            Divider()
                            ForEach(store.availableLabels, id: \.self) { label in
                                Toggle(
                                    label,
                                    isOn: Binding(
                                        get: { store.selectedLabels.contains(label) },
                                        set: { enabled in
                                            if enabled {
                                                store.selectedLabels.insert(label)
                                            } else {
                                                store.selectedLabels.remove(label)
                                            }
                                        }
                                    )
                                )
                            }
                        } label: {
                            Text(store.selectedLabels.isEmpty ? "全部" : store.selectedLabels.sorted().joined(separator: " / "))
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 6) {
                        Text("时间")
                            .foregroundStyle(.secondary)
                        Button(store.dateFilterDisplayName) {
                            isDateFilterPresented.toggle()
                        }
                        .popover(isPresented: $isDateFilterPresented, arrowEdge: .top) {
                            MeetingDateFilterPopover(store: store)
                        }
                    }
                }

                Divider()
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 10) {
                ScrollView {
                    folderSection
                }
                .frame(width: 150)
                .focusable()
                .focused($focusedNavigationColumn, equals: .folders)
                .focusEffectDisabled()
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            focusedNavigationColumn == .folders
                                ? Color(nsColor: .separatorColor)
                                : .clear,
                            lineWidth: 1
                        )
                }
                .onMoveCommand { direction in
                    handleMoveCommand(direction, in: .folders)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("会议纪要")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if store.selectedFolderID == store.trashFolder.id,
                           store.meetingCount(in: store.trashFolder) > 0 {
                            Button("清空") {
                                isEmptyingTrash = true
                            }
                            .buttonStyle(.borderless)
                            .help("永久删除回收站中的全部会议")
                        }
                        Text("\(store.filteredMeetings.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(store.filteredMeetings) { meeting in
                                MeetingListRow(
                                    meeting: meeting,
                                    labels: store.labels(for: meeting),
                                    displayDate: store.displayMeetingDate(for: meeting),
                                    isSelected: store.selectedMeetingIDs.contains(meeting.id)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    focusedNavigationColumn = .meetings
                                    store.selectMeeting(
                                        meeting,
                                        modifiers: NSApp.currentEvent?.modifierFlags ?? []
                                    )
                                }
                                .contextMenu {
                                    meetingContextMenu(for: meeting)
                                }
                                .onDrag {
                                    draggedMeetingProvider(for: meeting)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity, alignment: .top)
                    .focusable()
                    .focused($focusedNavigationColumn, equals: .meetings)
                    .focusEffectDisabled()
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                focusedNavigationColumn == .meetings
                                    ? Color(nsColor: .separatorColor)
                                    : .clear,
                                lineWidth: 1
                            )
                    }
                    .onMoveCommand { direction in
                        handleMoveCommand(direction, in: .meetings)
                    }

                    Button {
                        openNewMeetingWindow()
                    } label: {
                        Label("新增会议", systemImage: "plus")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(0.14))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .layoutPriority(1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("新建文件夹", isPresented: $isCreatingFolder) {
            TextField("文件夹名称", text: $pendingFolderName)
            Button("取消", role: .cancel) {
                pendingFolderName = ""
            }
            Button("创建") {
                let folder = store.createFolderReturningFolder(named: pendingFolderName)
                if let folder, !pendingMoveToNewFolderMeetingIDs.isEmpty {
                    store.selectedMeetingIDs = pendingMoveToNewFolderMeetingIDs
                    store.selectedMeetingID = pendingMoveToNewFolderMeetingIDs.first
                    store.moveSelectedMeetings(to: folder)
                }
                pendingFolderName = ""
                pendingMoveToNewFolderMeetingIDs = []
            }
        }
        .alert("重命名文件夹", isPresented: $isRenamingFolder) {
            TextField("文件夹名称", text: $pendingFolderName)
            Button("取消", role: .cancel) {
                pendingFolderName = ""
                folderBeingRenamed = nil
            }
            Button("保存") {
                if let folderBeingRenamed {
                    store.renameFolder(folderBeingRenamed, to: pendingFolderName)
                }
                pendingFolderName = ""
                folderBeingRenamed = nil
            }
        }
        .confirmationDialog(
            "确认清空回收站？",
            isPresented: $isEmptyingTrash,
            titleVisibility: .visible
        ) {
            Button("清空回收站", role: .destructive) {
                store.emptyTrash()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("回收站中的会议目录会被永久删除。")
        }
        .confirmationDialog(
            "确认永久删除？",
            isPresented: $isPermanentlyDeletingMeetings,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                store.permanentlyDelete(pendingPermanentDeletionMeetings)
                pendingPermanentDeletionMeetings = []
            }
            Button("取消", role: .cancel) {
                pendingPermanentDeletionMeetings = []
            }
        } message: {
            Text("所选会议的目录、录音、转录与纪要文件会立即从磁盘删除，无法恢复。")
        }
        .alert("重命名标签", isPresented: Binding(
            get: { quickLabelBeingRenamed != nil },
            set: { isPresented in
                if !isPresented {
                    quickLabelBeingRenamed = nil
                    pendingQuickLabelName = ""
                }
            }
        )) {
            TextField("标签名称", text: $pendingQuickLabelName)
            Button("取消", role: .cancel) {
                quickLabelBeingRenamed = nil
                pendingQuickLabelName = ""
            }
            Button("保存") {
                if let quickLabelBeingRenamed {
                    store.renameGlobalLabel(quickLabelBeingRenamed, to: pendingQuickLabelName)
                }
                quickLabelBeingRenamed = nil
                pendingQuickLabelName = ""
            }
        }
        .confirmationDialog(
            "更改纪要类型？",
            isPresented: Binding(
                get: { pendingMeetingTypeChange != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingMeetingTypeChange = nil
                        pendingMeetingTemplateID = ""
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("生成新纪要") {
                if let meeting = pendingMeetingTypeChange {
                    store.regenerateReport(for: meeting, templateID: pendingMeetingTemplateID)
                }
                pendingMeetingTypeChange = nil
                pendingMeetingTemplateID = ""
            }
            Button("取消", role: .cancel) {
                pendingMeetingTypeChange = nil
                pendingMeetingTemplateID = ""
            }
        } message: {
            Text(regenerateConfirmationMessage)
        }
        .confirmationDialog(
            "删除文件夹“\(folderPendingDeletion?.name ?? "")”？",
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        folderPendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: folderPendingDeletion
        ) { folder in
            Button("仅删除文件夹") {
                store.deleteFolder(folder)
                folderPendingDeletion = nil
            }
            Button("连同纪要及文件一起删除", role: .destructive) {
                folderPendingDeletion = nil
                folderPendingHardDeletion = folder
            }
            Button("取消", role: .cancel) {
                folderPendingDeletion = nil
            }
        } message: { folder in
            let count = store.meetingCount(in: folder)
            Text(
                count > 0
                    ? "该文件夹下有 \(count) 场会议纪要。可只删除文件夹（纪要移到“未分类”），或连同纪要和对应文件一起永久删除。"
                    : "该文件夹为空，可直接删除。"
            )
        }
        .confirmationDialog(
            "确认永久删除？",
            isPresented: Binding(
                get: { folderPendingHardDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        folderPendingHardDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: folderPendingHardDeletion
        ) { folder in
            Button("永久删除文件夹及纪要", role: .destructive) {
                store.deleteFolder(folder, deletingMeetings: true)
                folderPendingHardDeletion = nil
            }
            Button("取消", role: .cancel) {
                folderPendingHardDeletion = nil
            }
        } message: { folder in
            Text(
                "文件夹“\(folder.name)”及其中 \(store.meetingCount(in: folder)) 场会议的目录、录音、转录与纪要文件将被永久删除，无法恢复。"
            )
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let meeting = store.selectedMeeting {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(for: meeting)
                    summary(for: meeting)
                    labelsEditor(for: meeting)
                    notesEditor(for: meeting)
                    speakerEditor(for: meeting)
                    relatedMeetings(for: meeting)
                }
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .task(id: meeting.sessionID) {
                ensureDraft(for: meeting)
            }
        } else {
            ContentUnavailableView(
                "暂无匹配会议",
                systemImage: "doc.text.magnifyingglass",
                description: Text("调整搜索词或标签筛选。")
            )
        }
    }

    private func header(for meeting: MeetingRecord) -> some View {
        let draft = currentDraft(for: meeting)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(meeting.title)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button("撤销") {
                        detailDrafts[meeting.sessionID] = store.detailDraft(for: meeting)
                    }
                    .disabled(!hasUnsavedChanges(for: meeting))

                    Button("保存") {
                        store.saveDetailDraft(currentDraft(for: meeting), for: meeting)
                        detailDrafts[meeting.sessionID] = store.detailDraft(for: meeting)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasUnsavedChanges(for: meeting))
                }
            }

            HStack(spacing: 12) {
                Label("生成：\(meeting.createdAtDisplay)", systemImage: "calendar")
                Menu {
                    ForEach(templateStore.templates) { template in
                        Button {
                            let currentTemplateID = normalizedMeetingTypeID(for: meeting.meetingType)
                            guard currentTemplateID != template.id else {
                                return
                            }
                            pendingMeetingTypeChange = meeting
                            pendingMeetingTemplateID = template.id
                        } label: {
                            Label(
                                template.name,
                                systemImage: normalizedMeetingTypeID(for: meeting.meetingType) == template.id
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                        }
                    }
                } label: {
                    Label(meetingTypeDisplayName(for: meeting.meetingType), systemImage: "tag")
                }
                .menuStyle(.borderlessButton)
                Label(meeting.version == "named" ? "实名版" : "匿名版", systemImage: "person.2")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if let actualMeetingDate = draft.actualMeetingDate {
                    DatePicker(
                        "会议时间",
                        selection: Binding(
                            get: { actualMeetingDate },
                            set: { newValue in
                                updateDraft(for: meeting) { $0.actualMeetingDate = newValue }
                            }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.field)

                    Button {
                        updateDraft(for: meeting) { $0.actualMeetingDate = nil }
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .help("清除真实会议时间")
                } else {
                    Button {
                        updateDraft(for: meeting) { $0.actualMeetingDate = meeting.createdAt ?? Date() }
                    } label: {
                        Label("设置真实会议时间", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 8) {
                LibraryFileButton(title: "会议目录", systemImage: "folder", url: meeting.sessionURL)
                LibraryFileButton(
                    title: "HTML",
                    systemImage: "safari",
                    url: meeting.latestHTMLURL,
                    isGenerating: store.isGeneratingExport(for: meeting, format: "html")
                ) {
                    store.generateExport(for: meeting, format: "html")
                }
                LibraryFileButton(
                    title: "MD",
                    systemImage: "doc.plaintext",
                    url: meeting.latestMDURL,
                    isGenerating: store.isGeneratingExport(for: meeting, format: "md")
                ) {
                    store.generateExport(for: meeting, format: "md")
                }
                LibraryFileButton(
                    title: "DOCX",
                    systemImage: "doc.text",
                    url: meeting.latestDOCXURL,
                    isGenerating: store.isGeneratingExport(for: meeting, format: "docx")
                ) {
                    store.generateExport(for: meeting, format: "docx")
                }
                LibraryFileButton(
                    title: "PDF",
                    systemImage: "doc.richtext",
                    url: meeting.latestPDFURL,
                    isGenerating: store.isGeneratingExport(for: meeting, format: "pdf")
                ) {
                    store.generateExport(for: meeting, format: "pdf")
                }
                LibraryFileButton(title: "原始转录", systemImage: "text.quote", url: meeting.transcriptURL)
                Button {
                    openTranscriptWindow(meeting)
                } label: {
                    Label("查看/编辑转录", systemImage: "waveform.and.mic")
                }
                .buttonStyle(.bordered)
                .disabled(meeting.transcriptSegmentsURL == nil)
            }

            if store.regeneratingSessionIDs.contains(meeting.sessionID) {
                ProgressView("正在重新生成纪要")
                    .controlSize(.small)
            } else if let errorMessage = store.reportRegenerationError(for: meeting), !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func summary(for meeting: MeetingRecord) -> some View {
        GroupBox("内容") {
            VStack(alignment: .leading, spacing: 12) {
                if !meeting.takeaway.isEmpty {
                    Text(meeting.takeaway)
                        .font(.headline)
                }

                if !meeting.summary.isEmpty {
                    Text(meeting.summary)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !meeting.topics.isEmpty {
                    FlexibleChipRow(items: meeting.topics)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func labelsEditor(for meeting: MeetingRecord) -> some View {
        GroupBox("标签") {
            VStack(alignment: .leading, spacing: 8) {
                if draftLabels(for: meeting).isEmpty {
                    Text("尚未选择标签")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlexibleChipRow(
                        items: draftLabels(for: meeting).sorted(),
                        minimumWidth: 72,
                        maximumWidth: 150,
                        expandsItems: false,
                        columnSpacing: 6,
                        rowSpacing: 6
                    ) { label in
                        Button {
                            toggleDraftLabel(label, for: meeting)
                        } label: {
                            HStack(spacing: 4) {
                                Text(label)
                                    .lineLimit(1)
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.accentColor.opacity(0.14))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.accentColor.opacity(0.38))
                            )
                        }
                        .buttonStyle(.plain)
                        .help("点击移除该标签")
                    }
                }

                HStack(spacing: 8) {
                    TextField(
                        "输入自定义标签，可用逗号分隔",
                        text: customLabelBinding(for: meeting)
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        addCustomDraftLabels(for: meeting)
                    }

                    Button("添加") {
                        addCustomDraftLabels(for: meeting)
                    }
                    .disabled(customLabelText(for: meeting).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if !store.globalLabels.isEmpty {
                    FlexibleChipRow(
                        items: store.globalLabels,
                        minimumWidth: 88,
                        maximumWidth: 150,
                        expandsItems: false,
                        columnSpacing: 4,
                        rowSpacing: 4
                    ) { label in
                        let isSelected = draftLabels(for: meeting).contains(label)
                        Button {
                            toggleDraftLabel(label, for: meeting)
                        } label: {
                            Text(label)
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(
                                            isSelected
                                                ? Color.accentColor.opacity(0.18)
                                                : Color(nsColor: .controlBackgroundColor)
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(
                                            isSelected
                                                ? Color.accentColor.opacity(0.55)
                                                : Color(nsColor: .separatorColor),
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("重命名") {
                                quickLabelBeingRenamed = label
                                pendingQuickLabelName = label
                            }
                            Button("删除", role: .destructive) {
                                store.removeGlobalLabel(label)
                            }
                        }
                    }
                }

                Text("标签会参与筛选，也会用于跨会议归类。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notesEditor(for meeting: MeetingRecord) -> some View {
        GroupBox("备注") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(
                    text: draftBinding(for: meeting, keyPath: \.note)
                )
                .font(.body)
                .frame(minHeight: 96)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor))
                )

                Text("用于记录会后补充、检索线索或跟进提醒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func speakerEditor(for meeting: MeetingRecord) -> some View {
        GroupBox("说话人标注") {
            VStack(alignment: .leading, spacing: 10) {
                if meeting.detectedSpeakers.isEmpty {
                    Text("该会议没有可标注的说话人。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(meeting.detectedSpeakers, id: \.self) { speakerID in
                        HStack(spacing: 10) {
                            Text(speakerID)
                                .frame(width: 110, alignment: .leading)
                                .foregroundStyle(.secondary)

                            TextField(
                                "输入姓名或统一别名",
                                text: Binding(
                                    get: { currentDraft(for: meeting).speakerLabels[speakerID] ?? "" },
                                    set: { newValue in
                                        updateDraft(for: meeting) { $0.speakerLabels[speakerID] = newValue }
                                    }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                Text("跨 session 的说话人对齐基于人工标注；同一姓名会自动归到一起。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relatedMeetings(for meeting: MeetingRecord) -> some View {
        let relatedByTopic = store.relatedMeetingsByTopic(for: meeting)
        let relatedBySpeaker = store.relatedMeetingsBySpeaker(for: meeting)

        return GroupBox("关联") {
            VStack(alignment: .leading, spacing: 12) {
                RelatedMeetingRow(
                    title: "同主题",
                    meetings: relatedByTopic
                )
                RelatedMeetingRow(
                    title: "同一说话人",
                    meetings: relatedBySpeaker
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("文件夹")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    pendingFolderName = ""
                    isCreatingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("新建文件夹")
            }

            folderButton(title: "全部", count: store.meetings.filter {
                store.folder(for: $0)?.isTrash != true
            }.count, selected: store.selectedFolderID == nil, acceptsDrop: false) {
                store.selectFolder(nil)
                focusedNavigationColumn = .folders
            }

            ForEach(store.visibleFolders) { folder in
                folderButton(
                    title: folder.name,
                    count: store.meetingCount(in: folder),
                    selected: store.selectedFolderID == folder.id
                        || store.selectedFolderIDs.contains(folder.id),
                    highlighted: store.highlightedFolderID == folder.id,
                    dropTarget: folder
                ) {
                    store.selectFolder(
                        folder,
                        modifiers: NSApp.currentEvent?.modifierFlags ?? []
                    )
                    focusedNavigationColumn = .folders
                }
                .contextMenu {
                    folderContextMenu(for: folder)
                }
            }

            folderButton(
                title: store.uncategorizedFolder.name,
                count: store.meetingCount(in: store.uncategorizedFolder),
                selected: store.selectedFolderID == store.uncategorizedFolder.id,
                highlighted: store.highlightedFolderID == store.uncategorizedFolder.id,
                dropTarget: nil
            ) {
                store.selectFolder(store.uncategorizedFolder)
                focusedNavigationColumn = .folders
            }

            folderButton(
                title: store.trashFolder.name,
                count: store.meetingCount(in: store.trashFolder),
                selected: store.selectedFolderID == store.trashFolder.id,
                highlighted: store.highlightedFolderID == store.trashFolder.id,
                dropTarget: store.trashFolder
            ) {
                store.selectFolder(store.trashFolder)
                focusedNavigationColumn = .folders
            }
            .contextMenu {
                Button("清空回收站", role: .destructive) {
                    isEmptyingTrash = true
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("新建文件夹") {
                pendingFolderName = ""
                isCreatingFolder = true
            }
        }
    }

    private func folderButton(
        title: String,
        count: Int,
        selected: Bool,
        highlighted: Bool = false,
        dropTarget: LibraryFolder? = nil,
        acceptsDrop: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.12) : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        highlighted && !selected ? Color(nsColor: .separatorColor) : .clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .modifier(
            FolderDropModifier(
                isEnabled: acceptsDrop,
                dropTarget: dropTarget,
                handleDrop: handleMeetingDrop
            )
        )
    }

    @ViewBuilder
    private func folderContextMenu(for folder: LibraryFolder) -> some View {
        let selectedFolders = store.visibleFolders.filter {
            store.selectedFolderIDs.contains($0.id)
        }
        Button("重命名") {
            folderBeingRenamed = folder
            pendingFolderName = folder.name
            isRenamingFolder = true
        }
        Button("上移") {
            store.moveFolder(folder, offset: -1)
        }
        Button("下移") {
            store.moveFolder(folder, offset: 1)
        }
        Menu(selectedFolders.count > 1 && selectedFolders.contains(folder) ? "合并所选到" : "合并到") {
            ForEach(store.visibleFolders.filter { $0.id != folder.id }) { target in
                Button(target.name) {
                    if selectedFolders.count > 1, selectedFolders.contains(folder) {
                        store.mergeFolders(selectedFolders, into: target)
                    } else {
                        store.mergeFolder(folder, into: target)
                    }
                }
            }
        }
        Button("删除", role: .destructive) {
            folderPendingDeletion = folder
        }
    }

    @ViewBuilder
    private func meetingContextMenu(for meeting: MeetingRecord) -> some View {
        Button("打开文件夹") {
            FileOpener.open(meeting.sessionURL)
        }
        Menu("打开文件") {
            meetingFileMenuItem("HTML", url: meeting.latestHTMLURL, format: "html", meeting: meeting)
            meetingFileMenuItem("MD", url: meeting.latestMDURL, format: "md", meeting: meeting)
            meetingFileMenuItem("DOCX", url: meeting.latestDOCXURL, format: "docx", meeting: meeting)
            meetingFileMenuItem("PDF", url: meeting.latestPDFURL, format: "pdf", meeting: meeting)

            Button("原始转录") {
                FileOpener.open(meeting.transcriptURL)
            }
            .disabled(meeting.transcriptURL == nil)
        }
        Divider()
        Menu("挪至文件夹") {
            if store.folder(for: meeting) == nil {
                Button("新建文件夹…") {
                    store.ensureSelection(for: meeting)
                    pendingMoveToNewFolderMeetingIDs = store.selectedMeetingIDs
                    pendingFolderName = ""
                    isCreatingFolder = true
                }
            } else {
                Button("移出文件夹") {
                    store.ensureSelection(for: meeting)
                    store.moveSelectedMeetings(to: nil)
                }
            }
            ForEach(store.visibleFolders) { folder in
                Button(folder.name) {
                    store.ensureSelection(for: meeting)
                    store.moveSelectedMeetings(to: folder)
                }
            }
        }
        Menu("标签") {
            ForEach(store.globalLabels, id: \.self) { label in
                Button {
                    store.toggleLabel(label, for: meeting)
                } label: {
                    Label(
                        label,
                        systemImage: store.labels(for: meeting).contains(label)
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                }
            }
        }
        Menu("更改纪要模板") {
            ForEach(templateStore.templates) { template in
                Button {
                    let currentTemplateID = normalizedMeetingTypeID(for: meeting.meetingType)
                    guard currentTemplateID != template.id else {
                        return
                    }
                    pendingMeetingTypeChange = meeting
                    pendingMeetingTemplateID = template.id
                } label: {
                    Label(
                        template.name,
                        systemImage: normalizedMeetingTypeID(for: meeting.meetingType) == template.id
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                }
            }
        }
        .disabled(store.regeneratingSessionIDs.contains(meeting.sessionID))
        Divider()
        Button("选中全部当前结果") {
            store.selectAllFilteredMeetings()
        }
        if store.folder(for: meeting)?.isTrash == true {
            Button("永久删除", role: .destructive) {
                store.ensureSelection(for: meeting)
                pendingPermanentDeletionMeetings = store.meetings.filter {
                    store.selectedMeetingIDs.contains($0.id)
                }
                isPermanentlyDeletingMeetings = true
            }
        } else {
            Button("删除到回收站", role: .destructive) {
                store.ensureSelection(for: meeting)
                store.moveSelectedMeetingsToTrash()
            }
        }
    }

    @ViewBuilder
    private func meetingFileMenuItem(
        _ title: String,
        url: URL?,
        format: String,
        meeting: MeetingRecord
    ) -> some View {
        if let url {
            Button(title) {
                FileOpener.open(url)
            }
        } else {
            Button("生成\(title)") {
                store.ensureSelection(for: meeting)
                store.generateExport(for: meeting, format: format)
            }
            .disabled(store.isGeneratingExport(for: meeting, format: format))
        }
    }

    private func normalizedMeetingTypeID(for rawValue: String) -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if templateStore.templates.contains(where: { $0.id == trimmedValue }) {
            return trimmedValue
        }

        let underscoreValue = trimmedValue.replacingOccurrences(of: " ", with: "_")
        if templateStore.templates.contains(where: { $0.id == underscoreValue }) {
            return underscoreValue
        }

        if let matchingTemplate = templateStore.templates.first(where: { $0.name == trimmedValue }) {
            return matchingTemplate.id
        }

        return trimmedValue
    }

    private var regenerateConfirmationMessage: String {
        let base = "将按“\(meetingTypeDisplayName(for: pendingMeetingTemplateID))”重新生成纪要文件。"
        guard let meeting = pendingMeetingTypeChange else {
            return base
        }
        if store.hasNamedSpeakers(for: meeting) {
            return base + "已标注的说话人真实姓名会写入实名版纪要。"
        }
        return base + "如需实名版，可先在“说话人标注”中填写姓名并保存。"
    }

    private func meetingTypeDisplayName(for rawValue: String) -> String {
        let normalizedID = normalizedMeetingTypeID(for: rawValue)
        return templateStore.templates.first(where: { $0.id == normalizedID })?.name
            ?? rawValue
    }

    private func ensureDraft(for meeting: MeetingRecord) {
        if detailDrafts[meeting.sessionID] == nil {
            detailDrafts[meeting.sessionID] = store.detailDraft(for: meeting)
        }
    }

    private func currentDraft(for meeting: MeetingRecord) -> MeetingDetailDraft {
        detailDrafts[meeting.sessionID] ?? store.detailDraft(for: meeting)
    }

    private func hasUnsavedChanges(for meeting: MeetingRecord) -> Bool {
        currentDraft(for: meeting) != store.detailDraft(for: meeting)
    }

    private func updateDraft(
        for meeting: MeetingRecord,
        _ transform: (inout MeetingDetailDraft) -> Void
    ) {
        var draft = currentDraft(for: meeting)
        transform(&draft)
        detailDrafts[meeting.sessionID] = draft
    }

    private func draftBinding<Value>(
        for meeting: MeetingRecord,
        keyPath: WritableKeyPath<MeetingDetailDraft, Value>
    ) -> Binding<Value> {
        Binding(
            get: { currentDraft(for: meeting)[keyPath: keyPath] },
            set: { newValue in
                updateDraft(for: meeting) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func draftLabels(for meeting: MeetingRecord) -> Set<String> {
        Set(
            currentDraft(for: meeting)
                .labelsText
                .split(whereSeparator: { $0 == "," || $0 == "，" })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func customLabelText(for meeting: MeetingRecord) -> String {
        customLabelDrafts[meeting.sessionID] ?? ""
    }

    private func customLabelBinding(for meeting: MeetingRecord) -> Binding<String> {
        Binding(
            get: { customLabelText(for: meeting) },
            set: { customLabelDrafts[meeting.sessionID] = $0 }
        )
    }

    private func addCustomDraftLabels(for meeting: MeetingRecord) {
        let labels = MeetingLibraryStore.parseLabels(customLabelText(for: meeting))
        guard !labels.isEmpty else {
            return
        }
        let merged = draftLabels(for: meeting).union(labels)
        updateDraft(for: meeting) { $0.labelsText = merged.sorted().joined(separator: ", ") }
        customLabelDrafts[meeting.sessionID] = ""
    }

    private func toggleDraftLabel(_ label: String, for meeting: MeetingRecord) {
        var labels = draftLabels(for: meeting)
        if labels.contains(label) {
            labels.remove(label)
        } else {
            labels.insert(label)
        }
        updateDraft(for: meeting) { $0.labelsText = labels.sorted().joined(separator: ", ") }
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection, in column: NavigationColumn) {
        switch (column, direction) {
        case (.folders, .up):
            moveFolderSelection(offset: -1)
        case (.folders, .down):
            moveFolderSelection(offset: 1)
        case (.folders, .right):
            focusedNavigationColumn = .meetings
            ensureMeetingSelection()
        case (.meetings, .up):
            moveMeetingSelection(offset: -1)
        case (.meetings, .down):
            moveMeetingSelection(offset: 1)
        case (.meetings, .left):
            focusedNavigationColumn = .folders
        default:
            break
        }
    }

    private func moveFolderSelection(offset: Int) {
        let folderIDs = [String?.none]
            + store.visibleFolders.map { Optional($0.id) }
            + [Optional(store.uncategorizedFolder.id)]
            + [Optional(store.trashFolder.id)]
        let currentIndex = folderIDs.firstIndex(of: store.selectedFolderID) ?? 0
        let targetIndex = min(max(currentIndex + offset, 0), folderIDs.count - 1)
        let targetID = folderIDs[targetIndex]
        if let targetID,
           let targetFolder = (store.visibleFolders + [store.uncategorizedFolder, store.trashFolder])
            .first(where: { $0.id == targetID }) {
            store.selectFolder(targetFolder)
        } else {
            store.selectFolder(nil)
        }
    }

    private func ensureMeetingSelection() {
        guard store.selectedMeeting == nil,
              let firstMeeting = store.filteredMeetings.first else {
            return
        }
        store.selectMeeting(firstMeeting)
    }

    private func moveMeetingSelection(offset: Int) {
        guard !store.filteredMeetings.isEmpty else {
            return
        }

        let currentID = store.selectedMeeting?.id
        let currentIndex = currentID.flatMap { id in
            store.filteredMeetings.firstIndex(where: { $0.id == id })
        } ?? 0
        let targetIndex = min(max(currentIndex + offset, 0), store.filteredMeetings.count - 1)
        store.selectMeeting(store.filteredMeetings[targetIndex])
    }

    private func draggedMeetingProvider(for meeting: MeetingRecord) -> NSItemProvider {
        let draggedIDs: [String]
        if store.selectedMeetingIDs.contains(meeting.id) {
            draggedIDs = store.filteredMeetings
                .map(\.id)
                .filter(store.selectedMeetingIDs.contains)
        } else {
            draggedIDs = [meeting.id]
        }
        return NSItemProvider(object: draggedIDs.joined(separator: "\n") as NSString)
    }

    private func handleMeetingDrop(
        _ providers: [NSItemProvider],
        into folder: LibraryFolder?
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.canLoadObject(ofClass: NSString.self)
        }) else {
            return false
        }

        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let rawValue = object as? NSString else {
                return
            }
            let ids = Set(
                rawValue
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            DispatchQueue.main.async {
                let meetings = store.meetings.filter { ids.contains($0.id) }
                guard !meetings.isEmpty else {
                    return
                }
                store.moveMeetings(meetings, to: folder)
            }
        }
        return true
    }
}

private struct FolderDropModifier: ViewModifier {
    let isEnabled: Bool
    let dropTarget: LibraryFolder?
    let handleDrop: ([NSItemProvider], LibraryFolder?) -> Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.onDrop(of: [UTType.plainText.identifier], isTargeted: nil) { providers in
                handleDrop(providers, dropTarget)
            }
        } else {
            content
        }
    }
}

enum MeetingOpenAfterCreation: String, CaseIterable, Identifiable {
    case none
    case html
    case docx
    case md
    case pdf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none:
            return "不自动打开"
        case .html:
            return "HTML"
        case .docx:
            return "DOCX"
        case .md:
            return "MD"
        case .pdf:
            return "PDF"
        }
    }

    var exportFormat: String? {
        switch self {
        case .none:
            return nil
        case .html:
            return "html"
        case .docx:
            return "docx"
        case .md:
            return "md"
        case .pdf:
            return "pdf"
        }
    }
}

struct NewMeetingWindowView: View {
    @ObservedObject var store: MeetingLibraryStore
    @ObservedObject var templateStore: MeetingTemplateCatalogStore
    let onCompleted: (LocalMeetingCreationResult, MeetingOpenAfterCreation) -> Void
    @AppStorage("preferredMainColorScheme") private var preferredMainColorScheme = "system"
    @State private var title = ""
    @State private var audioURL: URL?
    @State private var transcriptURL: URL?
    @State private var selectedTemplateID = "auto"
    @State private var openAfterCreation: MeetingOpenAfterCreation = .none
    @State private var exportHTML = true
    @State private var exportDOCX = true
    @State private var exportMD = false
    @State private var exportPDF = false

    private var exportFormats: Set<String> {
        var formats: Set<String> = []
        if exportHTML {
            formats.insert("html")
        }
        if exportDOCX {
            formats.insert("docx")
        }
        if exportMD {
            formats.insert("md")
        }
        if exportPDF {
            formats.insert("pdf")
        }
        if let exportFormat = openAfterCreation.exportFormat {
            formats.insert(exportFormat)
        }
        return formats
    }

    private var canCreateMeeting: Bool {
        (audioURL != nil || transcriptURL != nil)
            && !store.isCreatingLocalMeeting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新增会议")
                .font(.title3.weight(.semibold))

            GroupBox("基本信息") {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("会议名称（可留空，留空时自动生成）", text: $title)
                        .textFieldStyle(.roundedBorder)

                    Picker("会议类型", selection: $selectedTemplateID) {
                        Text("自动识别").tag("auto")
                        ForEach(templateStore.templates) { template in
                            Text(template.name).tag(template.id)
                        }
                    }
                    .frame(maxWidth: 320, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("材料") {
                VStack(alignment: .leading, spacing: 12) {
                    materialRow(
                        title: "录音",
                        url: audioURL,
                        placeholder: "可选，支持 m4a / mp3 / wav 等"
                    ) {
                        audioURL = chooseFile(
                            allowedExtensions: ["m4a", "mp3", "wav", "aac", "flac", "ogg", "opus", "mp4", "mov", "webm"]
                        )
                    } clearAction: {
                        audioURL = nil
                    }

                    materialRow(
                        title: "转录稿",
                        url: transcriptURL,
                        placeholder: "可选，提供后将直接生成纪要"
                    ) {
                        transcriptURL = chooseFile(
                            allowedExtensions: ["txt", "md", "markdown", "csv", "srt", "vtt"]
                        )
                    } clearAction: {
                        transcriptURL = nil
                    }

                    Text("同时提供录音和转录稿时，将保留录音，并优先使用现成转录稿生成纪要。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("导出文件") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        Toggle("HTML", isOn: exportBinding(for: .html))
                        Toggle("DOCX", isOn: exportBinding(for: .docx))
                        Toggle("MD", isOn: exportBinding(for: .md))
                        Toggle("PDF", isOn: exportBinding(for: .pdf))
                    }
                    .toggleStyle(.checkbox)

                    HStack(spacing: 10) {
                        Text("完成后打开纪要文件")
                        Picker("完成后打开纪要文件", selection: $openAfterCreation) {
                            ForEach(MeetingOpenAfterCreation.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                    }

                    Text("HTML 和 DOCX 默认勾选，也可按需取消；MD、PDF 可选。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)

            Divider()

            HStack(spacing: 12) {
                if store.isCreatingLocalMeeting {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.localMeetingCreationMessage.isEmpty ? "正在处理" : store.localMeetingCreationMessage)
                        .foregroundStyle(.secondary)
                } else if let localMeetingCreationError = store.localMeetingCreationError,
                          !localMeetingCreationError.isEmpty {
                    Text(localMeetingCreationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("至少选择一份录音或转录稿。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    store.createLocalMeeting(
                        request: LocalMeetingCreationRequest(
                            title: title,
                            audioURL: audioURL,
                            transcriptURL: transcriptURL,
                            templateID: selectedTemplateID,
                            exportFormats: exportFormats
                        )
                    ) { result in
                        if let result {
                            onCompleted(result, openAfterCreation)
                        }
                    }
                } label: {
                    Label("开始生成", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreateMeeting)
            }
        }
        .padding(18)
        .frame(minWidth: 700, minHeight: 560)
        .preferredColorScheme(AppAppearance.resolvedColorScheme(for: preferredMainColorScheme))
        .onChange(of: openAfterCreation) { _, _ in
            ensureOpenAfterExportIsChecked()
        }
    }

    private func exportBinding(for option: MeetingOpenAfterCreation) -> Binding<Bool> {
        Binding(
            get: {
                switch option {
                case .html:
                    return exportHTML
                case .docx:
                    return exportDOCX
                case .md:
                    return exportMD
                case .pdf:
                    return exportPDF
                case .none:
                    return false
                }
            },
            set: { newValue in
                let value = openAfterCreation == option ? true : newValue
                switch option {
                case .html:
                    exportHTML = value
                case .docx:
                    exportDOCX = value
                case .md:
                    exportMD = value
                case .pdf:
                    exportPDF = value
                case .none:
                    break
                }
            }
        )
    }

    private func ensureOpenAfterExportIsChecked() {
        switch openAfterCreation {
        case .html:
            exportHTML = true
        case .docx:
            exportDOCX = true
        case .md:
            exportMD = true
        case .pdf:
            exportPDF = true
        case .none:
            break
        }
    }

    @ViewBuilder
    private func materialRow(
        title: String,
        url: URL?,
        placeholder: String,
        chooseAction: @escaping () -> Void,
        clearAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 58, alignment: .leading)
            Text(url?.lastPathComponent ?? placeholder)
                .foregroundStyle(url == nil ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("选择", action: chooseAction)
            if url != nil {
                Button {
                    clearAction()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chooseFile(allowedExtensions: [String]) -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct TranscriptEditorWindowView: View {
    @ObservedObject var store: MeetingLibraryStore
    let meeting: MeetingRecord
    @AppStorage("preferredMainColorScheme") private var preferredMainColorScheme = "system"
    @State private var segments: [TranscriptSegment] = []
    @State private var followPlayback = true
    @StateObject private var playerModel = TranscriptAudioPlayerModel()

    private var activeSegmentID: UUID? {
        segments.first(where: {
            playerModel.currentTime >= $0.start
                && playerModel.currentTime < $0.end
        })?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("原始转录")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("保存") {
                    store.saveTranscriptSegments(segments, for: meeting)
                }
            }

            TranscriptAudioPlayer(
                audioURL: meeting.audioURL,
                model: playerModel
            )

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach($segments) { $segment in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("\(timestamp(segment.start)) - \(timestamp(segment.end))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    TextField("说话人", text: $segment.speaker)
                                        .frame(width: 150)
                                        .textFieldStyle(.roundedBorder)
                                }

                                TextEditor(text: $segment.text)
                                    .font(.body)
                                    .frame(minHeight: 54)
                                    .padding(4)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(
                                                activeSegmentID == segment.id
                                                    ? Color.accentColor
                                                    : Color(nsColor: .separatorColor),
                                                lineWidth: activeSegmentID == segment.id ? 1.5 : 1
                                            )
                                    )
                            }
                            .padding(10)
                            .background(
                                activeSegmentID == segment.id
                                    ? Color.accentColor.opacity(0.08)
                                    : Color(nsColor: .controlBackgroundColor)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .id(segment.id)
                        }
                    }
                }
                .onChange(of: activeSegmentID) { _, newValue in
                    guard followPlayback, let newValue else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Toggle("播放时跟随转录", isOn: $followPlayback)
                    .toggleStyle(.checkbox)
                Spacer()
                Text(playerModel.timeDisplay)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text("\(segments.count) 段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 560)
        .preferredColorScheme(AppAppearance.resolvedColorScheme(for: preferredMainColorScheme))
        .onAppear {
            segments = store.transcriptSegments(for: meeting)
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(
            format: "%02d:%02d:%02d",
            total / 3600,
            (total % 3600) / 60,
            total % 60
        )
    }
}

private struct TranscriptAudioPlayer: View {
    let audioURL: URL?
    @ObservedObject var model: TranscriptAudioPlayerModel

    var body: some View {
        GroupBox("录音") {
            if let audioURL {
                VStack(alignment: .leading, spacing: 10) {
                    Text(audioURL.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            model.togglePlayback()
                        } label: {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .frame(width: 16)
                        }
                        .buttonStyle(.bordered)

                        Slider(
                            value: Binding(
                                get: { model.progress },
                                set: { model.seek(to: $0) }
                            ),
                            in: 0...1
                        )

                        Text(model.timeDisplay)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .onAppear {
                    model.load(url: audioURL)
                }
                .onDisappear {
                    model.stop()
                }
            } else {
                Text("该 session 没有可用的原始录音文件。")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

final class TranscriptAudioPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var progress = 0.0
    @Published var timeDisplay = "00:00 / 00:00"
    @Published var currentTime = 0.0

    private var player: AVPlayer?
    private var observer: Any?

    func load(url: URL) {
        stop()
        let player = AVPlayer(url: url)
        self.player = player
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            guard let self, let player else {
                return
            }
            let current = time.seconds.isFinite ? time.seconds : 0
            let duration = player.currentItem?.duration.seconds ?? 0
            self.currentTime = current
            self.progress = duration > 0 ? min(max(current / duration, 0), 1) : 0
            self.timeDisplay = "\(self.format(current)) / \(self.format(duration))"
        }
    }

    func togglePlayback() {
        guard let player else {
            return
        }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    func seek(to progress: Double) {
        guard let player,
              let duration = player.currentItem?.duration.seconds,
              duration.isFinite,
              duration > 0 else {
            return
        }
        let seconds = duration * min(max(progress, 0), 1)
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func stop() {
        player?.pause()
        if let observer, let player {
            player.removeTimeObserver(observer)
        }
        player = nil
        observer = nil
        isPlaying = false
        progress = 0
        currentTime = 0
        timeDisplay = "00:00 / 00:00"
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite else {
            return "00:00"
        }
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct MeetingListRow: View {
    let meeting: MeetingRecord
    let labels: [String]
    let displayDate: String
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.title)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(displayDate)
                if !labels.isEmpty {
                    Text(labels.joined(separator: " / "))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        )
    }
}

private struct MeetingDateFilterPopover: View {
    @ObservedObject var store: MeetingLibraryStore
    @State private var visibleMonth = Date()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("范围", selection: $store.dateFilterMode) {
                ForEach(LibraryDateFilterMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Button {
                    visibleMonth = calendar.date(byAdding: .month, value: -1, to: visibleMonth) ?? visibleMonth
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Spacer()

                Text(monthTitle)
                    .font(.headline)

                Spacer()

                Button {
                    visibleMonth = calendar.date(byAdding: .month, value: 1, to: visibleMonth) ?? visibleMonth
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
            }

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(weekdayTitles, id: \.self) { weekday in
                    Text(weekday)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(monthGrid.enumerated()), id: \.offset) { _, date in
                    if let date {
                        Button {
                            select(date)
                        } label: {
                            Text("\(calendar.component(.day, from: date))")
                                .fontWeight(store.hasMeeting(on: date) ? .bold : .regular)
                                .foregroundStyle(foregroundColor(for: date))
                                .frame(maxWidth: .infinity)
                                .frame(height: 26)
                                .background(background(for: date))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(height: 26)
                    }
                }
            }

            if store.dateFilterMode == .range {
                Text("\(shortDate(store.dateFilterStart)) - \(shortDate(store.dateFilterEnd))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear {
            visibleMonth = store.dateFilterStart
        }
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: visibleMonth)
    }

    private var weekdayTitles: [String] {
        ["日", "一", "二", "三", "四", "五", "六"]
    }

    private var monthGrid: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: visibleMonth) else {
            return []
        }

        let firstWeekday = calendar.component(.weekday, from: interval.start)
        let leadingEmptyCount = firstWeekday - 1
        let dayCount = calendar.range(of: .day, in: .month, for: visibleMonth)?.count ?? 0

        var dates = Array<Date?>(repeating: nil, count: leadingEmptyCount)
        dates += (0..<dayCount).compactMap {
            calendar.date(byAdding: .day, value: $0, to: interval.start)
        }
        return dates
    }

    private func select(_ date: Date) {
        switch store.dateFilterMode {
        case .all:
            store.dateFilterMode = .single
            store.dateFilterStart = date
            store.dateFilterEnd = date
        case .single:
            store.dateFilterStart = date
            store.dateFilterEnd = date
        case .range:
            if calendar.isDate(store.dateFilterStart, inSameDayAs: store.dateFilterEnd) {
                if date < store.dateFilterStart {
                    store.dateFilterStart = date
                } else {
                    store.dateFilterEnd = date
                }
            } else {
                store.dateFilterStart = date
                store.dateFilterEnd = date
            }
        }
    }

    private func foregroundColor(for date: Date) -> Color {
        if isSelected(date) {
            return .white
        }

        return store.hasMeeting(on: date) ? .green : .primary
    }

    @ViewBuilder
    private func background(for date: Date) -> some View {
        if isSelected(date) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor)
        } else {
            Color.clear
        }
    }

    private func isSelected(_ date: Date) -> Bool {
        switch store.dateFilterMode {
        case .all:
            return false
        case .single:
            return calendar.isDate(date, inSameDayAs: store.dateFilterStart)
        case .range:
            let start = calendar.startOfDay(for: min(store.dateFilterStart, store.dateFilterEnd))
            let end = calendar.startOfDay(for: max(store.dateFilterStart, store.dateFilterEnd))
            let day = calendar.startOfDay(for: date)
            return day >= start && day <= end
        }
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct LibraryFileButton: View {
    let title: String
    let systemImage: String
    let url: URL?
    var isGenerating = false
    var generateFile: (() -> Void)?

    var body: some View {
        let isMissingGeneratedFile = url == nil && generateFile != nil
        Button {
            if let url {
                FileOpener.open(url)
            } else {
                NSSound.beep()
            }
        } label: {
            Label(isGenerating ? "生成中" : title, systemImage: isGenerating ? "hourglass" : systemImage)
                .foregroundStyle(isMissingGeneratedFile ? .secondary : .primary)
        }
        .buttonStyle(.bordered)
        .opacity(isMissingGeneratedFile ? 0.58 : 1)
        .disabled(isGenerating || (url == nil && generateFile == nil))
        .contextMenu {
            if url == nil, let generateFile {
                Button("生成文件") {
                    generateFile()
                }
                .disabled(isGenerating)
            } else {
                Button("打开") {
                    FileOpener.open(url)
                }
                Button("打开方式...") {
                    FileOpener.openWithApplicationPicker(url)
                }
                Button("快速查看") {
                    FileOpener.quickLook(url)
                }
                Button("定位到文件") {
                    FileOpener.reveal(url)
                }
            }
        }
    }
}

private struct OverviewPanel<Content: View>: View {
    let title: String
    let accentColor: Color
    @ViewBuilder let content: Content

    init(title: String, accentColor: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accentColor = accentColor
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(accentColor)
                .frame(height: 4)

            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.headline)
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.45))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + horizontalSpacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + verticalSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? horizontalSpacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(
            width: maxWidth.isFinite ? maxWidth : totalWidth,
            height: totalHeight
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct FlexibleChipRow<Content: View>: View {
    let items: [String]
    let content: ((String) -> Content)?
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat?
    let expandsItems: Bool
    let columnSpacing: CGFloat
    let rowSpacing: CGFloat

    init(items: [String]) where Content == Text {
        self.items = items
        self.content = nil
        self.minimumWidth = 140
        self.maximumWidth = nil
        self.expandsItems = true
        self.columnSpacing = 8
        self.rowSpacing = 8
    }

    init(
        items: [String],
        minimumWidth: CGFloat = 140,
        maximumWidth: CGFloat? = nil,
        expandsItems: Bool = true,
        columnSpacing: CGFloat = 8,
        rowSpacing: CGFloat = 8,
        @ViewBuilder content: @escaping (String) -> Content
    ) {
        self.items = items
        self.content = content
        self.minimumWidth = minimumWidth
        self.maximumWidth = maximumWidth
        self.expandsItems = expandsItems
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
    }

    var body: some View {
        FlowLayout(horizontalSpacing: columnSpacing, verticalSpacing: rowSpacing) {
            ForEach(items, id: \.self) { item in
                if let content {
                    content(item)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Text(item)
                        .font(.caption)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RelatedMeetingRow: View {
    let title: String
    let meetings: [MeetingRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))

            if meetings.isEmpty {
                Text("暂无")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(meetings.prefix(4)) { meeting in
                    Button {
                        FileOpener.open(meeting.latestHTMLURL ?? meeting.latestPDFURL ?? meeting.sessionURL)
                    } label: {
                        HStack {
                            Text(meeting.title)
                                .lineLimit(1)
                            Spacer()
                            Text(meeting.createdAtDisplay)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
