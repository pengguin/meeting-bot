import SwiftUI

struct MeetingBotMenuView: View {
    @ObservedObject var store: BotRuntimeStore
    let openMainWindow: () -> Void
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @AppStorage("preferredMainColorScheme") private var preferredMainColorScheme = "system"

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                runtimeSection
                Divider()
                controlsSection
                Divider()
                recentMeetingSection
            }
            .padding(14)
        }
        .frame(width: 440, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 14))
        .preferredColorScheme(AppAppearance.resolvedColorScheme(for: preferredMainColorScheme))
        .onAppear {
            store.refresh()
            if notificationsEnabled {
                store.requestNotificationPermissionIfNeeded()
            }
        }
        .onChange(of: notificationsEnabled) { _, enabled in
            if enabled {
                store.requestNotificationPermissionIfNeeded()
            }
        }
    }

    private var header: some View {
        HStack {
            Text("会议纪要助手")
                .font(.headline)
            Spacer()
            Button(action: openMainWindow) {
                Label("打开主界面", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "运行状态")

            HStack(spacing: 10) {
                CompactMetric(
                    title: "状态",
                    value: store.launchStatus.displayName,
                    systemImage: store.launchStatus.symbolName,
                    color: store.launchStatus.tintColor
                )

                CompactMetric(
                    title: "任务",
                    value: store.runtimeStatus?.taskDisplayName ?? "未读取",
                    systemImage: store.runtimeStatus?.taskSymbolName ?? "circle.dashed",
                    color: store.runtimeStatus?.taskTintColor ?? .secondary
                )

                CompactMetric(
                    title: "环境",
                    value: store.environmentSummary,
                    systemImage: store.unhealthyEnvironmentChecks.isEmpty
                        ? "checkmark.shield"
                        : "exclamationmark.shield",
                    color: store.unhealthyEnvironmentChecks.isEmpty ? .green : .orange
                )
            }

            if let status = store.runtimeStatus {
                StatusRow(
                    title: "当前阶段",
                    value: status.stageDisplayName,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    color: .blue
                )
                StatusRow(
                    title: "最近更新",
                    value: status.updatedAtDisplay,
                    systemImage: "clock",
                    color: .secondary
                )

            } else {
                Text("尚未读取到任务状态")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !store.unhealthyEnvironmentChecks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.unhealthyEnvironmentChecks) { check in
                        Text("\(check.title)：\(check.detail)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Text(runtimeMessage)
                .font(.callout)
                .foregroundStyle(runtimeMessageColor)
                .lineLimit(3)
        }
    }

    private var recentMeetingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "最近一次会议")

            if let meeting = store.latestMeeting {
                Text(meeting.titleDisplayName)
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    Label(meeting.versionDisplayName, systemImage: "doc.badge.gearshape")
                    Label(meeting.createdAtDisplay, systemImage: "calendar")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let status = store.runtimeStatus, !status.sessionID.isEmpty {
                Text(status.sessionID)
                    .font(.headline)
                Text(status.stageDisplayName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无会议结果")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                SmallActionButton(title: "目录", systemImage: "folder") {
                    store.openLatestSession()
                }
                .disabled(store.latestSessionURL == nil)

                SmallActionButton(title: "HTML", systemImage: "safari") {
                    store.openLatestHTML()
                }
                .disabled(store.latestHTMLURL == nil)

                SmallActionButton(title: "MD", systemImage: "doc.plaintext") {
                    store.openLatestMD()
                }
                .disabled(store.latestMDURL == nil)

                SmallActionButton(title: "DOCX", systemImage: "doc.text") {
                    store.openLatestDOCX()
                }
                .disabled(store.latestDOCXURL == nil)

                SmallActionButton(title: "PDF", systemImage: "doc.richtext") {
                    store.openLatestPDF()
                }
                .disabled(store.latestPDFURL == nil)
            }
            .buttonStyle(.bordered)
        }
    }

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "操作")

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
        }
    }

    private var runtimeMessage: String {
        if let errorMessage = store.visibleErrorMessage, !errorMessage.isEmpty {
            return errorMessage
        }

        if store.launchStatus == .stopped || store.launchStatus == .missing {
            return "机器人后台服务已停止"
        }

        if let message = store.runtimeStatus?.message, !message.isEmpty {
            return message
        }

        return "机器人后台服务运行中"
    }

    private var runtimeMessageColor: Color {
        if let errorMessage = store.visibleErrorMessage, !errorMessage.isEmpty {
            return .red
        }

        if store.launchStatus == .stopped || store.launchStatus == .missing {
            return .orange
        }

        return .secondary
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.callout)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
    }
}

struct StatusRow: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)

            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

private struct CompactMetric: View {
    let title: String
    let value: String
    let systemImage: String
    let color: Color

    var body: some View {
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
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SmallActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
    }
}

struct ShortcutButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(width: 70)
        }
    }
}

extension LaunchAgentStatus {
    var tintColor: Color {
        switch self {
        case .running:
            return .green
        case .stopped:
            return .orange
        case .unknown:
            return .secondary
        case .missing:
            return .red
        }
    }
}

extension RuntimeStatus {
    var taskSymbolName: String {
        switch taskStatus {
        case "processing":
            return "waveform"
        case "done":
            return "checkmark.circle.fill"
        case "error":
            return "exclamationmark.triangle.fill"
        default:
            return "circle"
        }
    }

    var taskTintColor: Color {
        switch taskStatus {
        case "processing":
            return .blue
        case "done":
            return .green
        case "error":
            return .red
        default:
            return .secondary
        }
    }
}
